// File: axis_packet_parser.sv
// Author: Wyatt Krogh
// Description: Streaming 64-bit AXI4-Stream binary market data parser.
//              Decodes framing, performs big-endian byte-order slicing,
//              and routes parsed commands directly to the order book.

`timescale 1ns / 1ps

import md_types_pkg::*;

module axis_packet_parser #(
    parameter int unsigned DATA_WIDTH = AXIS_DATA_WIDTH,
    parameter int unsigned KEEP_WIDTH = AXIS_KEEP_WIDTH
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // AXI4-Stream interface from MAC/UDP deframer
    input  logic [DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]    s_axis_tkeep,
    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic                     s_axis_tlast,
    input  logic                     s_axis_tuser,   // Frame error indicator (FCS/CRC error from MAC)

    // Decoded message bus to order book core
    output parsed_md_msg_t           m_parsed_msg,
    output logic                     m_parsed_valid,
    input  logic                     m_parsed_ready,

    // Status and diagnostic telemetry
    output parser_error_flags_t      error_flags,
    output logic                     parse_error_pulse,
    output logic [31:0]              rx_packet_count,
    output logic [31:0]              parsed_msg_count,
    output logic [31:0]              dropped_packet_count
);

  typedef enum logic [2:0] {
    ST_IDLE      = 3'b000,
    ST_WORD1_ORD = 3'b001,
    ST_WORD2_PRQ = 3'b010,
    ST_EMIT      = 3'b011,
    ST_DROP_REST = 3'b100
  } parse_state_e;

  parse_state_e state_q, state_d;

  parsed_md_msg_t msg_buffer_q, msg_buffer_d;
  logic [15:0]    latency_cnt_q, latency_cnt_d;
  parser_error_flags_t error_flags_q, error_flags_d;
  logic           parse_err_pulse_q, parse_err_pulse_d;

  logic [31:0] rx_pkt_cnt_q, rx_pkt_cnt_d;
  logic [31:0] parsed_msg_cnt_q, parsed_msg_cnt_d;
  logic [31:0] dropped_pkt_cnt_q, dropped_pkt_cnt_d;

  // Cut-through flow control: accept beats whenever not stalled in EMIT
  assign s_axis_tready        = (state_q != ST_EMIT) || (state_q == ST_EMIT && m_parsed_ready);
  assign m_parsed_msg         = msg_buffer_q;
  assign m_parsed_valid       = (state_q == ST_EMIT);
  assign error_flags          = error_flags_q;
  assign parse_error_pulse    = parse_err_pulse_q;
  assign rx_packet_count      = rx_pkt_cnt_q;
  assign parsed_msg_count     = parsed_msg_cnt_q;
  assign dropped_packet_count = dropped_pkt_cnt_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q            <= ST_IDLE;
      msg_buffer_q       <= '0;
      latency_cnt_q      <= '0;
      error_flags_q      <= '0;
      parse_err_pulse_q  <= 1'b0;
      rx_pkt_cnt_q       <= '0;
      parsed_msg_cnt_q   <= '0;
      dropped_pkt_cnt_q  <= '0;
    end else begin
      state_q            <= state_d;
      msg_buffer_q       <= msg_buffer_d;
      latency_cnt_q      <= latency_cnt_d;
      error_flags_q      <= error_flags_d;
      parse_err_pulse_q  <= parse_err_pulse_d;
      rx_pkt_cnt_q       <= rx_pkt_cnt_d;
      parsed_msg_cnt_q   <= parsed_msg_cnt_d;
      dropped_pkt_cnt_q  <= dropped_pkt_cnt_d;
    end
  end

  always_comb begin
    logic [7:0] msg_type_raw;

    state_d            = state_q;
    msg_buffer_d       = msg_buffer_q;
    latency_cnt_d      = latency_cnt_q;
    error_flags_d      = error_flags_q;
    parse_err_pulse_d  = 1'b0;
    rx_pkt_cnt_d       = rx_pkt_cnt_q;
    parsed_msg_cnt_d   = parsed_msg_cnt_q;
    dropped_pkt_cnt_d  = dropped_pkt_cnt_q;
    msg_type_raw       = s_axis_tdata[63:56];

    latency_cnt_d = (state_q != ST_IDLE) ? (latency_cnt_q + 16'd1) : 16'd0;

    case (state_q)
      ST_IDLE: begin
        if (s_axis_tvalid && s_axis_tready) begin
          rx_pkt_cnt_d = rx_pkt_cnt_q + 1'b1;
          msg_buffer_d = '0;

          if (s_axis_tuser) begin
            // Ingress MAC FCS error: discard frame
            error_flags_d.invalid_checksum = 1'b1;
            parse_err_pulse_d              = 1'b1;
            dropped_pkt_cnt_d              = dropped_pkt_cnt_q + 1'b1;
            state_d                        = s_axis_tlast ? ST_IDLE : ST_DROP_REST;
          end else begin
            // Validate opcode against protocol spec
            if ((msg_type_raw == MSG_ADD)    ||
                (msg_type_raw == MSG_CANCEL) ||
                (msg_type_raw == MSG_MODIFY) ||
                (msg_type_raw == MSG_EXECUTE)) begin

              msg_buffer_d.msg_type = md_msg_type_e'(msg_type_raw);
              msg_buffer_d.side     = (s_axis_tdata[55:48] == 8'h01) ? SIDE_SELL : SIDE_BUY;
              msg_buffer_d.seq_num  = s_axis_tdata[47:16];

              if (s_axis_tlast) begin
                // Truncated packet: frame ended at header beat
                error_flags_d.length_mismatch = 1'b1;
                parse_err_pulse_d             = 1'b1;
                dropped_pkt_cnt_d             = dropped_pkt_cnt_q + 1'b1;
                state_d                       = ST_IDLE;
              end else begin
                state_d = ST_WORD1_ORD;
              end

            end else begin
              error_flags_d.unknown_msg_type = 1'b1;
              parse_err_pulse_d              = 1'b1;
              dropped_pkt_cnt_d              = dropped_pkt_cnt_q + 1'b1;
              state_d                        = s_axis_tlast ? ST_IDLE : ST_DROP_REST;
            end
          end
        end
      end

      ST_WORD1_ORD: begin
        if (s_axis_tvalid && s_axis_tready) begin
          if (s_axis_tuser) begin
            error_flags_d.invalid_checksum = 1'b1;
            parse_err_pulse_d              = 1'b1;
            dropped_pkt_cnt_d              = dropped_pkt_cnt_q + 1'b1;
            state_d                        = s_axis_tlast ? ST_IDLE : ST_DROP_REST;
          end else begin
            msg_buffer_d.order_id = s_axis_tdata[63:0];

            if (s_axis_tlast) begin
              // Cancel orders can terminate early if no price/qty payload is sent
              if (msg_buffer_q.msg_type == MSG_CANCEL) begin
                msg_buffer_d.price           = '0;
                msg_buffer_d.qty             = '0;
                msg_buffer_d.ingress_latency = latency_cnt_q + 16'd1;
                state_d                      = ST_EMIT;
              end else begin
                error_flags_d.length_mismatch = 1'b1;
                parse_err_pulse_d             = 1'b1;
                dropped_pkt_cnt_d             = dropped_pkt_cnt_q + 1'b1;
                state_d                       = ST_IDLE;
              end
            end else begin
              state_d = ST_WORD2_PRQ;
            end
          end
        end
      end

      ST_WORD2_PRQ: begin
        if (s_axis_tvalid && s_axis_tready) begin
          if (s_axis_tuser) begin
            error_flags_d.invalid_checksum = 1'b1;
            parse_err_pulse_d              = 1'b1;
            dropped_pkt_cnt_d              = dropped_pkt_cnt_q + 1'b1;
            state_d                        = s_axis_tlast ? ST_IDLE : ST_DROP_REST;
          end else begin
            msg_buffer_d.price           = s_axis_tdata[63:32];
            msg_buffer_d.qty             = s_axis_tdata[31:0];
            msg_buffer_d.ingress_latency = latency_cnt_q + 16'd1;

            if (s_axis_tlast) begin
              state_d = ST_EMIT;
            end else begin
              // Overflow beyond 24 bytes
              error_flags_d.length_mismatch = 1'b1;
              parse_err_pulse_d             = 1'b1;
              dropped_pkt_cnt_d             = dropped_pkt_cnt_q + 1'b1;
              state_d                       = ST_DROP_REST;
            end
          end
        end
      end

      ST_EMIT: begin
        if (m_parsed_ready) begin
          parsed_msg_cnt_d = parsed_msg_cnt_q + 1'b1;
          state_d          = ST_IDLE;
        end
      end

      ST_DROP_REST: begin
        if (s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
          state_d = ST_IDLE;
        end
      end

      default: state_d = ST_IDLE;
    endcase
  end

endmodule : axis_packet_parser
