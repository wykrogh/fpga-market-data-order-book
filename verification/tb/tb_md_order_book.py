"""
File: tb_md_order_book.py
Author: Wyatt Krogh
Description: Cocotb testbench environment for AXI4-Stream packet parser
             and pipelined limit order book core. Validates against GoldenOrderBook
             reference model and profiles cycle-accurate pipeline latency.
"""

import sys
import os
import random
from typing import List, Optional

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles
from cocotb.utils import get_sim_time

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "model"))
from golden_order_book import (
    GoldenOrderBook,
    MarketDataMessage,
    MsgType,
    Side,
    ExpectedBookEvent,
    BBOSnapshot,
)


class AXISStreamDriver:
    """Drives raw packet bytes over 64-bit AXI4-Stream interface."""

    def __init__(self, dut, clock, prefix: str = "s_axis"):
        self.dut = dut
        self.clock = clock
        self.tdata = getattr(dut, f"{prefix}_tdata")
        self.tkeep = getattr(dut, f"{prefix}_tkeep")
        self.tvalid = getattr(dut, f"{prefix}_tvalid")
        self.tready = getattr(dut, f"{prefix}_tready")
        self.tlast = getattr(dut, f"{prefix}_tlast")
        self.tuser = getattr(dut, f"{prefix}_tuser")

        self.tdata.value = 0
        self.tkeep.value = 0
        self.tvalid.value = 0
        self.tlast.value = 0
        self.tuser.value = 0

    async def send_packet(self, packet_bytes: bytes, error_inject: bool = False, stall_prob: float = 0.0):
        rem = len(packet_bytes) % 8
        padded = packet_bytes if rem == 0 else packet_bytes + b"\x00" * (8 - rem)
        num_beats = len(padded) // 8

        for beat_idx in range(num_beats):
            if stall_prob > 0.0 and random.random() < stall_prob:
                self.tvalid.value = 0
                await ClockCycles(self.clock, random.randint(1, 3))

            chunk = padded[beat_idx * 8 : (beat_idx + 1) * 8]
            word_val = int.from_bytes(chunk, byteorder="big")
            is_last = 1 if beat_idx == (num_beats - 1) else 0

            self.tdata.value = word_val
            self.tkeep.value = 0xFF
            self.tvalid.value = 1
            self.tlast.value = is_last
            self.tuser.value = 1 if (is_last and error_inject) else 0

            while True:
                await RisingEdge(self.clock)
                if int(self.tready.value) == 1:
                    break

        self.tvalid.value = 0
        self.tlast.value = 0
        self.tuser.value = 0


class BookEventMonitor:
    """Samples outbound event bus and direct BBO ports on accepted transactions."""

    def __init__(self, dut, clock):
        self.dut = dut
        self.clock = clock
        self.captured_events: List[dict] = []
        self._running = False

    async def start(self):
        self._running = True
        while self._running:
            await RisingEdge(self.clock)
            if int(self.dut.m_book_event_valid.value) == 1 and int(self.dut.m_book_event_ready.value) == 1:
                evt = {
                    "seq_num": int(self.dut.m_book_event.value.seq_num),
                    "cause_msg_type": int(self.dut.m_book_event.value.cause_msg_type),
                    "side": int(self.dut.m_book_event.value.side),
                    "event_price": int(self.dut.m_book_event.value.event_price),
                    "event_qty": int(self.dut.m_book_event.value.event_qty),
                    "bbo_changed": bool(self.dut.m_book_event.value.bbo_changed),
                    "best_bid_price": int(self.dut.bbo_best_bid_price.value),
                    "best_bid_qty": int(self.dut.bbo_best_bid_qty.value),
                    "bid_valid": bool(self.dut.bbo_bid_valid.value),
                    "best_ask_price": int(self.dut.bbo_best_ask_price.value),
                    "best_ask_qty": int(self.dut.bbo_best_ask_qty.value),
                    "ask_valid": bool(self.dut.bbo_ask_valid.value),
                    "pipeline_latency": int(self.dut.telemetry_latest_latency.value),
                    "sim_time_ns": get_sim_time("ns"),
                }
                self.captured_events.append(evt)

    def stop(self):
        self._running = False


class OrderBookScoreboard:
    """Compares RTL transactions against GoldenOrderBook and checks latency."""

    def __init__(self, dut, golden_model: GoldenOrderBook, monitor: Optional[BookEventMonitor] = None):
        self.dut = dut
        self.golden = golden_model
        self.monitor = monitor
        self.expected_events: List[ExpectedBookEvent] = []
        self.match_count = 0
        self.mismatch_count = 0
        self.latency_samples: List[int] = []

    def record_expected(self, expected_evt: ExpectedBookEvent):
        self.expected_events.append(expected_evt)

    def check_transaction(self, actual: dict, expected: ExpectedBookEvent) -> bool:
        diffs = []
        if actual["seq_num"] != expected.seq_num:
            diffs.append(f"SeqNum (act={actual['seq_num']} vs exp={expected.seq_num})")
        if actual["cause_msg_type"] != int(expected.cause_msg_type):
            diffs.append(f"MsgType (act={actual['cause_msg_type']} vs exp={int(expected.cause_msg_type)})")
        if actual["event_price"] != expected.event_price:
            diffs.append(f"Price (act={actual['event_price']} vs exp={expected.event_price})")
        if actual["event_qty"] != expected.event_qty:
            diffs.append(f"Qty (act={actual['event_qty']} vs exp={expected.event_qty})")
        if actual["best_bid_price"] != expected.bbo.best_bid_price:
            diffs.append(f"BidPrice (act={actual['best_bid_price']} vs exp={expected.bbo.best_bid_price})")
        if actual["best_bid_qty"] != expected.bbo.best_bid_qty:
            diffs.append(f"BidQty (act={actual['best_bid_qty']} vs exp={expected.bbo.best_bid_qty})")
        if actual["best_ask_price"] != expected.bbo.best_ask_price:
            diffs.append(f"AskPrice (act={actual['best_ask_price']} vs exp={expected.bbo.best_ask_price})")
        if actual["best_ask_qty"] != expected.bbo.best_ask_qty:
            diffs.append(f"AskQty (act={actual['best_ask_qty']} vs exp={expected.bbo.best_ask_qty})")

        lat = actual.get("pipeline_latency", 0)
        if lat > 20:
            diffs.append(f"Pipeline latency exceeded 20-cycle threshold: {lat}")

        if not diffs:
            self.match_count += 1
            self.latency_samples.append(lat)
            return True
        else:
            self.mismatch_count += 1
            self.dut._log.error(f"[MISMATCH] Seq {expected.seq_num}: " + ", ".join(diffs))
            return False

    def verify(self):
        if not self.monitor:
            return
        captured = self.monitor.captured_events
        for act, exp in zip(captured, self.expected_events):
            self.check_transaction(act, exp)

        if len(captured) != len(self.expected_events):
            self.dut._log.warning(
                f"Count mismatch: {len(captured)} captured vs {len(self.expected_events)} expected"
            )

        if self.latency_samples:
            avg_lat = sum(self.latency_samples) / len(self.latency_samples)
            p99_lat = sorted(self.latency_samples)[int(len(self.latency_samples) * 0.99)]
            self.dut._log.info(
                f"Latency: min={min(self.latency_samples)} / avg={avg_lat:.1f} / p99={p99_lat} / max={max(self.latency_samples)} cycles"
            )

        assert self.mismatch_count == 0, f"Scoreboard detected {self.mismatch_count} mismatches"


class TestHarness:
    """Test environment fixture managing driver, monitor, and scoreboard."""

    def __init__(self, dut):
        self.dut = dut
        self.clock = Clock(dut.clk, 4, units="ns")  # 250 MHz
        self.driver = AXISStreamDriver(dut, self.clock)
        self.monitor = BookEventMonitor(dut, self.clock)
        self.golden = GoldenOrderBook(depth=5)
        self.scoreboard = OrderBookScoreboard(dut, self.golden, self.monitor)

    @classmethod
    async def create(cls, dut):
        tb = cls(dut)
        cocotb.start_soon(tb.clock.start())
        cocotb.start_soon(tb.monitor.start())
        await tb.reset()
        return tb

    async def reset(self):
        self.dut.rst_n.value = 0
        self.dut.s_axis_tvalid.value = 0
        self.dut.m_book_event_ready.value = 1
        await ClockCycles(self.clock, 5)
        self.dut.rst_n.value = 1
        await ClockCycles(self.clock, 5)

    async def send(self, msg: MarketDataMessage, stall_prob: float = 0.0):
        expected = self.golden.process_message(msg)
        self.scoreboard.record_expected(expected)
        pkt = GoldenOrderBook.pack_message(msg)
        await self.driver.send_packet(pkt, stall_prob=stall_prob)


def make_msg(msg_type: MsgType, side: Side, seq: int, order_id: int, price: int, qty: int) -> MarketDataMessage:
    return MarketDataMessage(
        msg_type=msg_type,
        side=side,
        seq_num=seq,
        order_id=order_id,
        price=price,
        qty=qty,
    )


@cocotb.test()
async def test_order_book_reset(dut):
    clock = Clock(dut.clk, 4, units="ns")
    cocotb.start_soon(clock.start())
    dut.rst_n.value = 0
    await ClockCycles(clock, 5)
    dut.rst_n.value = 1
    await ClockCycles(clock, 2)

    assert int(dut.bbo_bid_valid.value) == 0
    assert int(dut.bbo_ask_valid.value) == 0
    assert int(dut.telemetry_rx_packets.value) == 0


@cocotb.test()
async def test_single_add_order(dut):
    tb = await TestHarness.create(dut)
    msg = make_msg(MsgType.ADD, Side.BUY, seq=1, order_id=1001, price=15000, qty=50)
    await tb.send(msg)
    await ClockCycles(tb.clock, 20)
    tb.scoreboard.verify()


@cocotb.test()
async def test_two_sided_book_depth(dut):
    tb = await TestHarness.create(dut)
    orders = [
        make_msg(MsgType.ADD, Side.BUY, seq=1, order_id=101, price=10000, qty=10),
        make_msg(MsgType.ADD, Side.BUY, seq=2, order_id=102, price=10050, qty=25),
        make_msg(MsgType.ADD, Side.SELL, seq=3, order_id=201, price=10200, qty=15),
        make_msg(MsgType.ADD, Side.SELL, seq=4, order_id=202, price=10150, qty=30),
    ]
    for ord_msg in orders:
        await tb.send(ord_msg)
        await ClockCycles(tb.clock, 5)

    await ClockCycles(tb.clock, 25)
    tb.scoreboard.verify()


@cocotb.test()
async def test_order_cancellation(dut):
    tb = await TestHarness.create(dut)
    msg1 = make_msg(MsgType.ADD, Side.BUY, seq=1, order_id=5001, price=9500, qty=100)
    msg2 = make_msg(MsgType.ADD, Side.BUY, seq=2, order_id=5002, price=9550, qty=50)
    msg3 = make_msg(MsgType.CANCEL, Side.BUY, seq=3, order_id=5002, price=9550, qty=50)

    for m in [msg1, msg2, msg3]:
        await tb.send(m)
        await ClockCycles(tb.clock, 5)

    await ClockCycles(tb.clock, 25)
    tb.scoreboard.verify()


@cocotb.test()
async def test_burst_packet_stream(dut):
    tb = await TestHarness.create(dut)
    base_bid = 50000
    base_ask = 50100

    for i in range(50):
        side = Side.BUY if (i % 2 == 0) else Side.SELL
        price = (base_bid - (i * 5)) if side == Side.BUY else (base_ask + (i * 5))
        msg = make_msg(MsgType.ADD, side, seq=i + 1, order_id=10000 + i, price=price, qty=10 * (i + 1))
        await tb.send(msg, stall_prob=0.1)

    await ClockCycles(tb.clock, 40)
    tb.scoreboard.verify()
