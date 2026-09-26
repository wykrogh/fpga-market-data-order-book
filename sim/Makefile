# Cocotb simulation Makefile for FPGA Market Data Parser & Order Book
# Simulator: Verilator or Icarus Verilog

# Default simulator: verilator or icarus
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# Paths
RTL_DIR = $(PWD)/../rtl
TB_DIR  = $(PWD)/../verification/tb
MODEL_DIR = $(PWD)/../verification/model

# SystemVerilog Source Files (in strict compilation order)
VERILOG_SOURCES = \
    $(RTL_DIR)/pkg/md_types_pkg.sv \
    $(RTL_DIR)/parser/axis_packet_parser.sv \
    $(RTL_DIR)/book/order_book_core.sv \
    $(RTL_DIR)/top/md_order_book_top.sv

# Top-level module name in RTL
TOPLEVEL = md_order_book_top

# Python cocotb test module name
MODULE = tb_md_order_book

# Set PYTHONPATH to include testbench and golden model directories
export PYTHONPATH := $(TB_DIR):$(MODEL_DIR):$(PYTHONPATH)

# Simulator specific compilation flags
ifeq ($(SIM),verilator)
    # Enable FST waveform tracing, relaxed lint warnings, SystemVerilog 2017 standard
    EXTRA_ARGS += --trace-fst --trace-structs
    EXTRA_ARGS += -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-fatal
    EXTRA_ARGS += --timing
else ifeq ($(SIM),icarus)
    # Enable IEEE 1800-2012 SystemVerilog features
    COMPILE_ARGS += -g2012
    PLUSARGS += +fst
endif

# Cocotb simulation rules include
include $(shell cocotb-config --makefiles)/Makefile.sim

# Convenience targets
.PHONY: waves clean_all help

waves:
	@echo "Opening waveform viewer..."
	@which gtkwave > /dev/null 2>&1 && gtkwave dump.fst || \
	 which surfer > /dev/null 2>&1 && surfer dump.fst || \
	 echo "Neither gtkwave nor surfer found. Please install a viewer or view dump.fst directly."

clean_all: clean
	@rm -rf __pycache__ $(TB_DIR)/__pycache__ $(MODEL_DIR)/__pycache__
	@rm -rf *.fst *.vcd *.xml results.xml sim_build
	@echo "Clean completed."

help:
	@echo "Usage:"
	@echo "  make SIM=verilator          Run simulation using Verilator"
	@echo "  make SIM=icarus             Run simulation using Icarus Verilog"
	@echo "  make TESTCASE=<test_name>   Run a specific cocotb testcase"
	@echo "  make waves                  Launch GTKWave/Surfer to inspect waveforms"
	@echo "  make clean_all              Remove all simulation build artifacts and traces"
