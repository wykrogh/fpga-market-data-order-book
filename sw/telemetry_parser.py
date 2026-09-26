#!/usr/bin/env python3
"""
File: telemetry_parser.py
Author: Wyatt Krogh
Description: Telemetry decoder and latency profiler for FPGA order book events.
             Calculates percentile distributions and renders ASCII depth ladders.
"""

import argparse
import struct
import sys
import math
import random
from typing import List, Tuple


def calculate_percentile(sorted_data: List[float], percentile: float) -> float:
    """Calculates percentile from sorted data using linear interpolation."""
    if not sorted_data:
        return 0.0
    k = (len(sorted_data) - 1) * (percentile / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return float(sorted_data[int(k)])
    d0 = sorted_data[int(f)] * (c - k)
    d1 = sorted_data[int(c)] * (k - f)
    return float(d0 + d1)


def render_ascii_ladder(bids: List[Tuple[float, int]], asks: List[Tuple[float, int]]):
    """
    Renders an institutional-grade ASCII price-depth ladder.
    """
    print("\n" + "=" * 62)
    print(f"{'QUANTITY':>12} | {'BID PRICE':>14} || {'ASK PRICE':<14} | {'QUANTITY':<12}")
    print("=" * 62)

    max_rows = max(len(bids), len(asks))
    for i in range(max_rows):
        bid_str = ""
        if i < len(bids):
            bid_p, bid_q = bids[i]
            bid_str = f"{bid_q:>12,d} | {bid_p:>14.2f}"
        else:
            bid_str = f"{' ':>12} | {' ':>14}"

        ask_str = ""
        if i < len(asks):
            ask_p, ask_q = asks[i]
            ask_str = f"{ask_p:<14.2f} | {ask_q:<12,d}"
        else:
            ask_str = f"{' ':>14} | {' ':>12}"

        print(f"{bid_str} || {ask_str}")

    print("=" * 62 + "\n")


def analyze_latencies(latencies: List[int], clock_freq_mhz: float = 250.0):
    """
    Computes latency percentiles in cycles and nanoseconds using standard library.
    """
    if not latencies:
        print("No latency samples available.")
        return

    sorted_lats = sorted(latencies)
    n = len(sorted_lats)
    ns_per_cycle = 1000.0 / clock_freq_mhz

    p50 = calculate_percentile(sorted_lats, 50.0)
    p90 = calculate_percentile(sorted_lats, 90.0)
    p99 = calculate_percentile(sorted_lats, 99.0)
    p999 = calculate_percentile(sorted_lats, 99.9)

    min_val = sorted_lats[0]
    max_val = sorted_lats[-1]
    mean_val = sum(sorted_lats) / n

    print("=" * 50)
    print(f"      HARDWARE TICK-TO-TRADE LATENCY REPORT        ")
    print(f"      (FPGA Core Clock: {clock_freq_mhz:.1f} MHz, {ns_per_cycle:.2f} ns/clk) ")
    print("=" * 50)
    print(f" Sample Count  : {n:,d}")
    print(f" Min Latency   : {min_val:>6d} cycles  ({min_val*ns_per_cycle:>6.1f} ns)")
    print(f" Mean Latency  : {mean_val:>6.2f} cycles  ({mean_val*ns_per_cycle:>6.1f} ns)")
    print(f" Median (p50)  : {p50:>6.1f} cycles  ({p50*ns_per_cycle:>6.1f} ns)")
    print(f" p90 Latency   : {p90:>6.1f} cycles  ({p90*ns_per_cycle:>6.1f} ns)")
    print(f" p99 Latency   : {p99:>6.1f} cycles  ({p99*ns_per_cycle:>6.1f} ns)")
    print(f" p99.9 Latency : {p999:>6.1f} cycles  ({p999*ns_per_cycle:>6.1f} ns)")
    print(f" Max Latency   : {max_val:>6d} cycles  ({max_val*ns_per_cycle:>6.1f} ns)")
    print("=" * 50)


def generate_synthetic_demo():
    """Generates synthetic telemetry and displays analysis as a demonstration."""
    print("[*] Generating synthetic market events and hardware latency trace...")
    random.seed(42)

    # Simulate 5,000 tick-to-trade latency measurements (tight distribution: 12-16 cycles)
    base_latency = 12
    # Geometric distribution simulation
    latencies = []
    for _ in range(5000):
        # Geometric-like distribution:
        jitter = 0
        while random.random() > 0.6 and jitter < 15:
            jitter += 1
        latencies.append(base_latency + jitter)

    # Sample top-5 ladder snapshot
    bids = [
        (582.50, 4200),
        (582.40, 6800),
        (582.35, 12500),
        (582.20, 18000),
        (582.10, 25000),
    ]
    asks = [
        (582.55, 3100),
        (582.60, 5400),
        (582.70, 9200),
        (582.85, 14000),
        (583.00, 22000),
    ]

    render_ascii_ladder(bids, asks)
    analyze_latencies(latencies, clock_freq_mhz=250.0)


def main():
    parser = argparse.ArgumentParser(description="FPGA Market Data & Order Book Telemetry Parser")
    parser.add_argument("--demo", action="store_true", help="Run demonstration with synthetic telemetry trace")
    parser.add_argument("--clock-mhz", type=float, default=250.0, help="FPGA core clock frequency in MHz (default: 250.0)")
    args = parser.parse_args()

    if args.demo or len(sys.argv) == 1:
        generate_synthetic_demo()


if __name__ == "__main__":
    main()
