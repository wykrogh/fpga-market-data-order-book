// File: telemetry_parser.hpp
// Author: Wyatt Krogh
// Description: Zero-copy, cache-aligned telemetry packet decoder for FPGA
//              order book event streams (C++20).

#pragma once

#include <cstdint>
#include <cstring>
#include <span>
#include <string_view>
#include <iostream>
#include <iomanip>

namespace md::telemetry {

#pragma pack(push, 1)

enum class MsgType : uint8_t {
    None    = 0x00,
    Add     = 0x41, // 'A'
    Cancel  = 0x58, // 'X'
    Modify  = 0x4D, // 'M'
    Execute = 0x45  // 'E'
};

enum class Side : uint8_t {
    Buy  = 0,
    Sell = 1
};

struct HardwareTelemetryPacket {
    uint32_t seq_num;
    uint64_t timestamp_ns;
    MsgType  cause_msg_type;
    Side     side;
    uint32_t event_price;
    uint32_t event_qty;
    uint8_t  bbo_changed;
    uint32_t best_bid_price;
    uint32_t best_bid_qty;
    uint8_t  bid_valid;
    uint32_t best_ask_price;
    uint32_t best_ask_qty;
    uint8_t  ask_valid;
    uint16_t pipeline_latency_cycles;
};

#pragma pack(pop)

class TelemetryDecoder {
public:
    static inline const HardwareTelemetryPacket* decode_zero_copy(std::span<const uint8_t> buffer) noexcept {
        if (buffer.size() < sizeof(HardwareTelemetryPacket)) [[unlikely]] {
            return nullptr;
        }
        return reinterpret_cast<const HardwareTelemetryPacket*>(buffer.data());
    }

    static void print_packet(const HardwareTelemetryPacket& pkt, double clock_mhz = 250.0) noexcept {
        const double ns_per_cycle = 1000.0 / clock_mhz;
        const double latency_ns = pkt.pipeline_latency_cycles * ns_per_cycle;

        std::cout << "[TELEMETRY EVENT] Seq: " << pkt.seq_num
                  << " | Type: " << static_cast<char>(pkt.cause_msg_type)
                  << " | Side: " << (pkt.side == Side::Buy ? "BUY" : "SELL")
                  << " | Price: " << (pkt.event_price / 100.0)
                  << " | Qty: " << pkt.event_qty
                  << " | Latency: " << pkt.pipeline_latency_cycles << " cycles ("
                  << std::fixed << std::setprecision(1) << latency_ns << " ns)"
                  << "\n  BBO: Bid " << (pkt.best_bid_price / 100.0) << " x " << pkt.best_bid_qty
                  << " | Ask " << (pkt.best_ask_price / 100.0) << " x " << pkt.best_ask_qty
                  << " | Changed: " << (pkt.bbo_changed ? "TRUE" : "FALSE")
                  << std::endl;
    }
};

} // namespace md::telemetry
