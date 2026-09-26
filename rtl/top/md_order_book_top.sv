// File: md_order_book_top.sv
// Author: Wyatt Krogh
// Description: Top-level integration module connecting AXI4-Stream packet parser
//              to pipelined limit order book core. Direct-routes BBO register
//              bits to top-level I/O alongside structured event telemetry.

`timescale 1ns / 1ps

import md_types_pkg::*;

module md_order_book_top #(
    parameter int unsigned DATA_WIDTH = AXIS_DATA_WIDTH,
    parameter int unsigned KEEP_WIDTH = AXIS_KEEP_WIDTH,
    parameter int unsigned DEPTH      = BOOK_DEPTH
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Inbound AXI4-Stream bus
    input  logic [DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]    s_axis_tkeep,
    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic                     s_axis_tlast,
    input  logic                     s_axis_tuser,

    // Dedicated BBO trigger wires
    output logic [PRICE_WIDTH-1:0]   bbo_best_bid_price,
    output logic [QTY_WIDTH-1:0]     bbo_best_bid_qty,
    output logic                     bbo_bid_valid,
    output logic [PRICE_WIDTH-1:0]   bbo_best_ask_price,
    output logic [QTY_WIDTH-1:0]     bbo_best_ask_qty,
    output logic                     bbo_ask_valid,
    output logic                     bbo_trigger_pulse,

    // Outbound event telemetry
    output book_event_t              m_book_event,
    output logic                     m_book_event_valid,
    input  logic                     m_book_event_ready,

    // Status and diagnostic telemetry
    output parser_error_flags_t      telemetry_error_flags,
    output logic                     telemetry_parse_err_pulse,
    output logic [31:0]              telemetry_rx_packets,
    output logic [31:0]              telemetry_parsed_msgs,
    output logic [31:0]              telemetry_dropped_pkts,
    output logic [31:0]              telemetry_book_updates,
    output logic [31:0]              telemetry_bbo_changes,
    output logic [15:0]              telemetry_latest_latency
);

  parsed_md_msg_t parser_to_book_msg;
  logic           parser_to_book_valid;
  logic           parser_to_book_ready;

  book_level_t    bid_depth_ladder [DEPTH];
  book_level_t    ask_depth_ladder [DEPTH];
  bbo_snapshot_t  core_bbo;

  book_event_t    core_book_event;
  logic           core_event_valid;
  logic           core_event_ready;

  assign m_book_event             = core_book_event;
  assign m_book_event_valid       = core_event_valid;
  assign core_event_ready         = m_book_event_ready;

  assign bbo_best_bid_price       = core_bbo.best_bid_price;
  assign bbo_best_bid_qty         = core_bbo.best_bid_qty;
  assign bbo_bid_valid            = core_bbo.bid_valid;
  assign bbo_best_ask_price       = core_bbo.best_ask_price;
  assign bbo_best_ask_qty         = core_bbo.best_ask_qty;
  assign bbo_ask_valid            = core_bbo.ask_valid;
  assign bbo_trigger_pulse        = core_event_valid && core_book_event.bbo_changed;
  assign telemetry_latest_latency = core_book_event.pipeline_latency;

  axis_packet_parser #(
      .DATA_WIDTH(DATA_WIDTH),
      .KEEP_WIDTH(KEEP_WIDTH)
  ) u_parser (
      .clk                 (clk),
      .rst_n               (rst_n),
      .s_axis_tdata        (s_axis_tdata),
      .s_axis_tkeep        (s_axis_tkeep),
      .s_axis_tvalid       (s_axis_tvalid),
      .s_axis_tready       (s_axis_tready),
      .s_axis_tlast        (s_axis_tlast),
      .s_axis_tuser        (s_axis_tuser),
      .m_parsed_msg        (parser_to_book_msg),
      .m_parsed_valid      (parser_to_book_valid),
      .m_parsed_ready      (parser_to_book_ready),
      .error_flags         (telemetry_error_flags),
      .parse_error_pulse   (telemetry_parse_err_pulse),
      .rx_packet_count     (telemetry_rx_packets),
      .parsed_msg_count    (telemetry_parsed_msgs),
      .dropped_packet_count(telemetry_dropped_pkts)
  );

  order_book_core #(
      .DEPTH(DEPTH)
  ) u_book_core (
      .clk                (clk),
      .rst_n              (rst_n),
      .s_msg              (parser_to_book_msg),
      .s_msg_valid        (parser_to_book_valid),
      .s_msg_ready        (parser_to_book_ready),
      .m_event            (core_book_event),
      .m_event_valid      (core_event_valid),
      .m_event_ready      (core_event_ready),
      .bid_ladder         (bid_depth_ladder),
      .ask_ladder         (ask_depth_ladder),
      .current_bbo        (core_bbo),
      .total_updates_count(telemetry_book_updates),
      .bbo_change_count   (telemetry_bbo_changes)
  );

endmodule : md_order_book_top
