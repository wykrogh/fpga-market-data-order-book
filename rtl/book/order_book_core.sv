// File: order_book_core.sv
// Author: Wyatt Krogh
// Description: Pipelined L2/L3 limit order book tracking top-N bid and ask levels.
//              Uses an unrolled parallel comparator cascade to update depth levels
//              and extract top-of-book (BBO) within a single clock cycle.

`timescale 1ns / 1ps

import md_types_pkg::*;

module order_book_core #(
    parameter int unsigned DEPTH = BOOK_DEPTH
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Parsed message input from packet parser
    input  parsed_md_msg_t           s_msg,
    input  logic                     s_msg_valid,
    output logic                     s_msg_ready,

    // Emitted event bus
    output book_event_t              m_event,
    output logic                     m_event_valid,
    input  logic                     m_event_ready,

    // Parallel depth ladder outputs (top-of-rack registers)
    output book_level_t              bid_ladder [DEPTH],
    output book_level_t              ask_ladder [DEPTH],
    output bbo_snapshot_t            current_bbo,
    output logic [31:0]              total_updates_count,
    output logic [31:0]              bbo_change_count
);

  book_level_t bids_q [DEPTH], bids_d [DEPTH];
  book_level_t asks_q [DEPTH], asks_d [DEPTH];
  bbo_snapshot_t bbo_q, bbo_d;

  book_event_t event_out_q, event_out_d;
  logic        event_valid_q, event_valid_d;

  logic [31:0] updates_cnt_q, updates_cnt_d;
  logic [31:0] bbo_cnt_q, bbo_cnt_d;

  assign s_msg_ready         = !event_valid_q || m_event_ready;
  assign m_event             = event_out_q;
  assign m_event_valid       = event_valid_q;
  assign bid_ladder          = bids_q;
  assign ask_ladder          = asks_q;
  assign current_bbo         = bbo_q;
  assign total_updates_count = updates_cnt_q;
  assign bbo_change_count    = bbo_cnt_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        bids_q[i] <= '0;
        asks_q[i] <= '0;
      end
      bbo_q         <= '0;
      event_out_q   <= '0;
      event_valid_q <= 1'b0;
      updates_cnt_q <= '0;
      bbo_cnt_q     <= '0;
    end else begin
      bids_q        <= bids_d;
      asks_q        <= asks_d;
      bbo_q         <= bbo_d;
      event_out_q   <= event_out_d;
      event_valid_q <= event_valid_d;
      updates_cnt_q <= updates_cnt_d;
      bbo_cnt_q     <= bbo_cnt_d;
    end
  end

  // Combinational match, insert, and BBO extraction logic
  // Note: Unrolled parallel comparator cascade is chosen for DEPTH <= 8 to close timing
  // cleanly at 250 MHz on UltraScale+. Scales as O(DEPTH) LUTs per side.
  always_comb begin
    logic bbo_changed;

    bids_d        = bids_q;
    asks_d        = asks_q;
    bbo_d         = bbo_q;
    event_out_d   = event_out_q;
    event_valid_d = event_valid_q && !m_event_ready;
    updates_cnt_d = updates_cnt_q;
    bbo_cnt_d     = bbo_cnt_q;

    if (s_msg_valid && s_msg_ready) begin
      updates_cnt_d = updates_cnt_q + 1'b1;

      // Bid ladder (sorted descending: bids[0] is highest price)
      if (s_msg.side == SIDE_BUY) begin
        logic        hit_found;
        int unsigned hit_idx;
        logic        insert_found;
        int unsigned insert_idx;

        hit_found    = 1'b0;
        hit_idx      = 0;
        insert_found = 1'b0;
        insert_idx   = DEPTH;

        for (int i = 0; i < DEPTH; i++) begin
          if (bids_q[i].valid && (bids_q[i].price == s_msg.price)) begin
            hit_found = 1'b1;
            hit_idx   = i;
          end
        end

        for (int i = DEPTH - 1; i >= 0; i--) begin
          if (!bids_q[i].valid || (s_msg.price > bids_q[i].price)) begin
            insert_found = 1'b1;
            insert_idx   = i;
          end
        end

        case (s_msg.msg_type)
          MSG_ADD: begin
            if (hit_found) begin
              bids_d[hit_idx].total_qty   = bids_q[hit_idx].total_qty + s_msg.qty;
              bids_d[hit_idx].order_count = bids_q[hit_idx].order_count + 16'd1;
            end else if (insert_found) begin
              for (int k = DEPTH - 1; k > 0; k--) begin
                if (k > insert_idx) begin
                  bids_d[k] = bids_q[k - 1];
                end
              end
              bids_d[insert_idx].price       = s_msg.price;
              bids_d[insert_idx].total_qty   = s_msg.qty;
              bids_d[insert_idx].order_count = 16'd1;
              bids_d[insert_idx].valid       = 1'b1;
            end
          end

          MSG_CANCEL, MSG_EXECUTE: begin
            if (hit_found) begin
              if ((bids_q[hit_idx].total_qty <= s_msg.qty) || (bids_q[hit_idx].order_count <= 16'd1)) begin
                for (int k = 0; k < DEPTH - 1; k++) begin
                  if (k >= hit_idx) begin
                    bids_d[k] = bids_q[k + 1];
                  end
                end
                bids_d[DEPTH - 1] = '0;
              end else begin
                bids_d[hit_idx].total_qty   = bids_q[hit_idx].total_qty - s_msg.qty;
                bids_d[hit_idx].order_count = bids_q[hit_idx].order_count - 16'd1;
              end
            end
          end

          MSG_MODIFY: begin
            if (hit_found) begin
              bids_d[hit_idx].total_qty = s_msg.qty;
            end
          end

          default: ;
        endcase
      end

      // Ask ladder (sorted ascending: asks[0] is lowest price)
      else begin
        logic        hit_found;
        int unsigned hit_idx;
        logic        insert_found;
        int unsigned insert_idx;

        hit_found    = 1'b0;
        hit_idx      = 0;
        insert_found = 1'b0;
        insert_idx   = DEPTH;

        for (int i = 0; i < DEPTH; i++) begin
          if (asks_q[i].valid && (asks_q[i].price == s_msg.price)) begin
            hit_found = 1'b1;
            hit_idx   = i;
          end
        end

        for (int i = DEPTH - 1; i >= 0; i--) begin
          if (!asks_q[i].valid || (s_msg.price < asks_q[i].price)) begin
            insert_found = 1'b1;
            insert_idx   = i;
          end
        end

        case (s_msg.msg_type)
          MSG_ADD: begin
            if (hit_found) begin
              asks_d[hit_idx].total_qty   = asks_q[hit_idx].total_qty + s_msg.qty;
              asks_d[hit_idx].order_count = asks_q[hit_idx].order_count + 16'd1;
            end else if (insert_found) begin
              for (int k = DEPTH - 1; k > 0; k--) begin
                if (k > insert_idx) begin
                  asks_d[k] = asks_q[k - 1];
                end
              end
              asks_d[insert_idx].price       = s_msg.price;
              asks_d[insert_idx].total_qty   = s_msg.qty;
              asks_d[insert_idx].order_count = 16'd1;
              asks_d[insert_idx].valid       = 1'b1;
            end
          end

          MSG_CANCEL, MSG_EXECUTE: begin
            if (hit_found) begin
              if ((asks_q[hit_idx].total_qty <= s_msg.qty) || (asks_q[hit_idx].order_count <= 16'd1)) begin
                for (int k = 0; k < DEPTH - 1; k++) begin
                  if (k >= hit_idx) begin
                    asks_d[k] = asks_q[k + 1];
                  end
                end
                asks_d[DEPTH - 1] = '0;
              end else begin
                asks_d[hit_idx].total_qty   = asks_q[hit_idx].total_qty - s_msg.qty;
                asks_d[hit_idx].order_count = asks_q[hit_idx].order_count - 16'd1;
              end
            end
          end

          MSG_MODIFY: begin
            if (hit_found) begin
              asks_d[hit_idx].total_qty = s_msg.qty;
            end
          end

          default: ;
        endcase
      end

      // Top of book extraction
      if (bids_d[0].valid) begin
        bbo_d.best_bid_price = bids_d[0].price;
        bbo_d.best_bid_qty   = bids_d[0].total_qty;
        bbo_d.bid_valid      = 1'b1;
      end else begin
        bbo_d.best_bid_price = '0;
        bbo_d.best_bid_qty   = '0;
        bbo_d.bid_valid      = 1'b0;
      end

      if (asks_d[0].valid) begin
        bbo_d.best_ask_price = asks_d[0].price;
        bbo_d.best_ask_qty   = asks_d[0].total_qty;
        bbo_d.ask_valid      = 1'b1;
      end else begin
        bbo_d.best_ask_price = '0;
        bbo_d.best_ask_qty   = '0;
        bbo_d.ask_valid      = 1'b0;
      end

      bbo_changed = (bbo_d.best_bid_price != bbo_q.best_bid_price) ||
                    (bbo_d.best_bid_qty   != bbo_q.best_bid_qty)   ||
                    (bbo_d.bid_valid      != bbo_q.bid_valid)      ||
                    (bbo_d.best_ask_price != bbo_q.best_ask_price) ||
                    (bbo_d.best_ask_qty   != bbo_q.best_ask_qty)   ||
                    (bbo_d.ask_valid      != bbo_q.ask_valid);

      if (bbo_changed) begin
        bbo_cnt_d = bbo_cnt_q + 1'b1;
      end

      // Output event assembly
      // pipeline_latency accounts for parser cycles + 1 register stage in core
      event_out_d.seq_num          = s_msg.seq_num;
      event_out_d.cause_msg_type   = s_msg.msg_type;
      event_out_d.side             = s_msg.side;
      event_out_d.event_price      = s_msg.price;
      event_out_d.event_qty        = s_msg.qty;
      event_out_d.bbo_changed      = bbo_changed;
      event_out_d.bbo              = bbo_d;
      event_out_d.pipeline_latency = s_msg.ingress_latency + 16'd1;
      event_valid_d                = 1'b1;
    end
  end

endmodule : order_book_core
