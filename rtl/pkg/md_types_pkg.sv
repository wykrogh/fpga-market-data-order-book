// File: md_types_pkg.sv
// Author: Wyatt Krogh
// Description: Type definitions, wire structures, and message enums for
//              streaming market data parser and limit order book core.
// Target: AMD UltraScale+ / Versal Prime

`ifndef MD_TYPES_PKG_SV
`define MD_TYPES_PKG_SV

package md_types_pkg;

  // Stream bus and field width parameters
  localparam int unsigned AXIS_DATA_WIDTH = 64;
  localparam int unsigned AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH / 8;
  localparam int unsigned ORDER_ID_WIDTH  = 64;
  localparam int unsigned PRICE_WIDTH     = 32;
  localparam int unsigned QTY_WIDTH       = 32;
  localparam int unsigned SEQ_NUM_WIDTH   = 32;
  localparam int unsigned TIMESTAMP_WIDTH = 64;
  localparam int unsigned BOOK_DEPTH      = 5;   // Active depth tracked per side

  // Inbound message opcodes
  typedef enum logic [7:0] {
    MSG_NONE    = 8'h00,
    MSG_ADD     = 8'h41, // 'A' : Add Order (id, side, price, qty)
    MSG_CANCEL  = 8'h58, // 'X' : Cancel/Delete Order (id)
    MSG_MODIFY  = 8'h4D, // 'M' : Modify/Replace Order (id, price, qty)
    MSG_EXECUTE = 8'h45  // 'E' : Trade execution fill (id, qty)
  } md_msg_type_e;

  typedef enum logic {
    SIDE_BUY  = 1'b0,
    SIDE_SELL = 1'b1
  } side_e;

  // Ingress parsing error flags
  typedef struct packed {
    logic invalid_checksum;
    logic unknown_msg_type;
    logic length_mismatch;
    logic sequence_gap;
    logic fifo_overflow;
    logic book_overflow;
  } parser_error_flags_t;

  // Normalized message emitted from AXI-Stream parser to book core
  typedef struct packed {
    logic [SEQ_NUM_WIDTH-1:0]   seq_num;
    logic [TIMESTAMP_WIDTH-1:0] timestamp_ns;
    md_msg_type_e               msg_type;
    side_e                      side;
    logic [ORDER_ID_WIDTH-1:0]  order_id;
    logic [PRICE_WIDTH-1:0]     price;
    logic [QTY_WIDTH-1:0]       qty;
    logic [15:0]                ingress_latency; // Parser cycle counter
  } parsed_md_msg_t;

  // Single price level in depth ladder
  typedef struct packed {
    logic [PRICE_WIDTH-1:0] price;
    logic [QTY_WIDTH-1:0]   total_qty;
    logic [15:0]            order_count;
    logic                   valid;
  } book_level_t;

  // Top of book state snapshot
  typedef struct packed {
    logic [PRICE_WIDTH-1:0] best_bid_price;
    logic [QTY_WIDTH-1:0]   best_bid_qty;
    logic                   bid_valid;
    logic [PRICE_WIDTH-1:0] best_ask_price;
    logic [QTY_WIDTH-1:0]   best_ask_qty;
    logic                   ask_valid;
    logic [TIMESTAMP_WIDTH-1:0] update_timestamp;
  } bbo_snapshot_t;

  // Telemetry event emitted on book updates
  typedef struct packed {
    logic [SEQ_NUM_WIDTH-1:0]   seq_num;
    md_msg_type_e               cause_msg_type;
    side_e                      side;
    logic [PRICE_WIDTH-1:0]     event_price;
    logic [QTY_WIDTH-1:0]       event_qty;
    logic                       bbo_changed;
    bbo_snapshot_t              bbo;
    logic [15:0]                pipeline_latency; // Total ingress-to-update cycles
  } book_event_t;

endpackage : md_types_pkg

`endif // MD_TYPES_PKG_SV
