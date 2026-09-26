#!/usr/bin/env python3
"""
File: control_client.py
Author: Wyatt Krogh
Description: Control and monitoring client for FPGA order book hardware CSRs.
"""

import argparse
import sys
import time
from dataclasses import dataclass


@dataclass
class HardwareCSRs:
    rx_packet_count: int = 0
    parsed_msg_count: int = 0
    dropped_packet_count: int = 0
    book_updates_count: int = 0
    bbo_change_count: int = 0
    error_flags_raw: int = 0
    latest_latency_cycles: int = 0


class OrderBookControlClient:
    """
    Control client interfacing with FPGA memory-mapped registers (PCIe / AXI-Lite).
    Provides mock and hardware backends.
    """

    def __init__(self, target_ip: str = "127.0.0.1", port: int = 8080, mock: bool = True):
        self.target_ip = target_ip
        self.port = port
        self.mock = mock
        self._mock_csrs = HardwareCSRs(
            rx_packet_count=128450,
            parsed_msg_count=128448,
            dropped_packet_count=2,
            book_updates_count=124010,
            bbo_change_count=34200,
            error_flags_raw=0,
            latest_latency_cycles=13,
        )

    def read_csrs(self) -> HardwareCSRs:
        """Reads hardware status and performance diagnostic registers."""
        if self.mock:
            return self._mock_csrs
        raise NotImplementedError("Physical PCIe/AXI-Lite driver interface requires FPGA hardware target.")

    def print_status_dashboard(self):
        """Displays live register status and parser health dashboard."""
        csrs = self.read_csrs()
        print("\n" + "=" * 54)
        print("     FPGA MARKET DATA CORE STATUS & CSR TELEMETRY     ")
        print("=" * 54)
        print(f" Inbound Packets RX       : {csrs.rx_packet_count:>12,d}")
        print(f" Parsed Messages          : {csrs.parsed_msg_count:>12,d}")
        print(f" Dropped/Corrupted Packets: {csrs.dropped_packet_count:>12,d}")
        print(f" Order Book Updates       : {csrs.book_updates_count:>12,d}")
        print(f" BBO Changes Triggered    : {csrs.bbo_change_count:>12,d}")
        print(f" Latest Pipeline Latency  : {csrs.latest_latency_cycles:>12d} cycles")
        print(f" Error Register (raw)     : 0x{csrs.error_flags_raw:08X}")
        print("=" * 54 + "\n")


def main():
    parser = argparse.ArgumentParser(description="FPGA Order Book Hardware Control Client")
    parser.add_argument("--status", action="store_true", help="Query and display hardware CSR registers")
    parser.add_argument("--mock", action="store_true", default=True, help="Use mock backend (default: True)")
    args = parser.parse_args()

    client = OrderBookControlClient(mock=args.mock)
    client.print_status_dashboard()


if __name__ == "__main__":
    main()
