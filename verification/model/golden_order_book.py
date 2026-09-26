"""
File: golden_order_book.py
Author: Wyatt Krogh
Description: Reference Limit Order Book (LOB) software model for verification.
             Parses raw binary packets and tracks sorted price levels.
"""

from dataclasses import dataclass, field
from enum import IntEnum
from typing import Dict, List, Optional, Tuple
import struct


class MsgType(IntEnum):
    NONE = 0x00
    ADD = 0x41      # 'A'
    CANCEL = 0x58   # 'X'
    MODIFY = 0x4D   # 'M'
    EXECUTE = 0x45  # 'E'


class Side(IntEnum):
    BUY = 0         # Bid
    SELL = 1        # Ask


@dataclass
class MarketDataMessage:
    msg_type: MsgType
    side: Side
    seq_num: int
    order_id: int
    price: int
    qty: int
    timestamp_ns: int = 0


@dataclass
class BookLevel:
    price: int
    total_qty: int
    order_count: int


@dataclass
class BBOSnapshot:
    best_bid_price: int = 0
    best_bid_qty: int = 0
    bid_valid: bool = False
    best_ask_price: int = 0
    best_ask_qty: int = 0
    ask_valid: bool = False


@dataclass
class ExpectedBookEvent:
    seq_num: int
    cause_msg_type: MsgType
    side: Side
    event_price: int
    event_qty: int
    bbo_changed: bool
    bbo: BBOSnapshot


class GoldenOrderBook:
    """
    Python Golden Reference Model for the hardware limit order book core.
    Maintains full order repository and top-N price level ladders.
    """

    def __init__(self, depth: int = 5):
        self.depth = depth
        self.orders: Dict[int, Tuple[Side, int, int]] = {}  # order_id -> (side, price, qty)
        self.bids: Dict[int, int] = {}  # price -> total_qty
        self.asks: Dict[int, int] = {}  # price -> total_qty
        self.bbo = BBOSnapshot()
        self.total_updates = 0
        self.bbo_changes = 0

    def process_message(self, msg: MarketDataMessage) -> ExpectedBookEvent:
        """
        Updates the golden book state and generates an ExpectedBookEvent.
        """
        old_bbo = BBOSnapshot(
            best_bid_price=self.bbo.best_bid_price,
            best_bid_qty=self.bbo.best_bid_qty,
            bid_valid=self.bbo.bid_valid,
            best_ask_price=self.bbo.best_ask_price,
            best_ask_qty=self.bbo.best_ask_qty,
            ask_valid=self.bbo.ask_valid,
        )

        if msg.msg_type == MsgType.ADD:
            self._handle_add(msg.order_id, msg.side, msg.price, msg.qty)
        elif msg.msg_type == MsgType.CANCEL:
            self._handle_cancel(msg.order_id)
        elif msg.msg_type == MsgType.MODIFY:
            self._handle_modify(msg.order_id, msg.price, msg.qty)
        elif msg.msg_type == MsgType.EXECUTE:
            self._handle_execute(msg.order_id, msg.qty)

        # Refresh BBO
        self._update_bbo()
        self.total_updates += 1

        bbo_changed = (
            self.bbo.best_bid_price != old_bbo.best_bid_price
            or self.bbo.best_bid_qty != old_bbo.best_bid_qty
            or self.bbo.bid_valid != old_bbo.bid_valid
            or self.bbo.best_ask_price != old_bbo.best_ask_price
            or self.bbo.best_ask_qty != old_bbo.best_ask_qty
            or self.bbo.ask_valid != old_bbo.ask_valid
        )

        if bbo_changed:
            self.bbo_changes += 1

        return ExpectedBookEvent(
            seq_num=msg.seq_num,
            cause_msg_type=msg.msg_type,
            side=msg.side,
            event_price=msg.price,
            event_qty=msg.qty,
            bbo_changed=bbo_changed,
            bbo=BBOSnapshot(
                best_bid_price=self.bbo.best_bid_price,
                best_bid_qty=self.bbo.best_bid_qty,
                bid_valid=self.bbo.bid_valid,
                best_ask_price=self.bbo.best_ask_price,
                best_ask_qty=self.bbo.best_ask_qty,
                ask_valid=self.bbo.ask_valid,
            ),
        )

    def _handle_add(self, order_id: int, side: Side, price: int, qty: int):
        self.orders[order_id] = (side, price, qty)
        target_dict = self.bids if side == Side.BUY else self.asks
        target_dict[price] = target_dict.get(price, 0) + qty

    def _handle_cancel(self, order_id: int):
        if order_id not in self.orders:
            return
        side, price, qty = self.orders.pop(order_id)
        target_dict = self.bids if side == Side.BUY else self.asks
        if price in target_dict:
            target_dict[price] -= qty
            if target_dict[price] <= 0:
                del target_dict[price]

    def _handle_modify(self, order_id: int, new_price: int, new_qty: int):
        if order_id not in self.orders:
            return
        side, _, _ = self.orders[order_id]
        self._handle_cancel(order_id)
        self._handle_add(order_id, side, new_price, new_qty)

    def _handle_execute(self, order_id: int, exec_qty: int):
        if order_id not in self.orders:
            return
        side, price, remaining_qty = self.orders[order_id]
        target_dict = self.bids if side == Side.BUY else self.asks
        deduct = min(exec_qty, remaining_qty)
        if price in target_dict:
            target_dict[price] -= deduct
            if target_dict[price] <= 0:
                del target_dict[price]
        new_rem = remaining_qty - deduct
        if new_rem <= 0:
            del self.orders[order_id]
        else:
            self.orders[order_id] = (side, price, new_rem)

    def _update_bbo(self):
        # Bids sorted descending
        valid_bids = [p for p in self.bids.keys() if self.bids[p] > 0]
        if valid_bids:
            best_bid = max(valid_bids)
            self.bbo.best_bid_price = best_bid
            self.bbo.best_bid_qty = self.bids[best_bid]
            self.bbo.bid_valid = True
        else:
            self.bbo.best_bid_price = 0
            self.bbo.best_bid_qty = 0
            self.bbo.bid_valid = False

        # Asks sorted ascending
        valid_asks = [p for p in self.asks.keys() if self.asks[p] > 0]
        if valid_asks:
            best_ask = min(valid_asks)
            self.bbo.best_ask_price = best_ask
            self.bbo.best_ask_qty = self.asks[best_ask]
            self.bbo.ask_valid = True
        else:
            self.bbo.best_ask_price = 0
            self.bbo.best_ask_qty = 0
            self.bbo.ask_valid = False

    def get_ladder(self) -> Tuple[List[Tuple[int, int]], List[Tuple[int, int]]]:
        """Returns sorted (price, qty) lists for top-N bids and asks."""
        sorted_bids = sorted(
            [(p, q) for p, q in self.bids.items() if q > 0],
            key=lambda x: x[0],
            reverse=True,
        )[: self.depth]
        sorted_asks = sorted(
            [(p, q) for p, q in self.asks.items() if q > 0],
            key=lambda x: x[0],
        )[: self.depth]
        return sorted_bids, sorted_asks

    @staticmethod
    def pack_message(msg: MarketDataMessage) -> bytes:
        """
        Packs a MarketDataMessage into 24-byte big-endian binary packet format:
        Word 0 (8B): msg_type(1B), side(1B), seq_num(4B), reserved(2B)
        Word 1 (8B): order_id(8B)
        Word 2 (8B): price(4B), qty(4B)
        """
        w0 = struct.pack("!BBIH", int(msg.msg_type), int(msg.side), msg.seq_num, 0)
        # Byte order: [msg_type (1B)][side (1B)][seq_num (4B)][reserved (2B)]
        w1 = struct.pack("!Q", msg.order_id)
        w2 = struct.pack("!II", msg.price, msg.qty)
        return w0 + w1 + w2
