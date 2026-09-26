#!/usr/bin/env bash
# Simulation runner script for cocotb (Verilator / Icarus)

set -euo pipefail

# ANSI color codes
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

SIM_NAME="verilator"
TESTCASE=""

show_help() {
    echo -e "${BOLD}Usage:${RESET} $0 [options]"
    echo ""
    echo "Options:"
    echo "  -s, --sim <name>       Simulator to use (default: verilator, choices: verilator, icarus)"
    echo "  -t, --test <name>      Run specific testcase (e.g. test_single_add_order)"
    echo "  -w, --waves            Open waveform in viewer after simulation"
    echo "  -c, --clean            Clean build directory and simulation artifacts"
    echo "  -h, --help             Show this help message"
    echo ""
}

# Parse command line flags
OPEN_WAVES=0
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--sim)
            SIM_NAME="$2"
            shift 2
            ;;
        -t|--test)
            TESTCASE="$2"
            shift 2
            ;;
        -w|--waves)
            OPEN_WAVES=1
            shift
            ;;
        -c|--clean)
            DO_CLEAN=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${RESET}"
            show_help
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ${DO_CLEAN} -eq 1 ]]; then
    echo -e "${CYAN}Cleaning simulation build artifacts...${RESET}"
    make clean_all
    exit 0
fi

echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}${CYAN}  FPGA Market Data & Order Book Simulation Runner     ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e " Simulator : ${GREEN}${SIM_NAME}${RESET}"
if [[ -n "${TESTCASE}" ]]; then
    echo -e " Target Test: ${YELLOW}${TESTCASE}${RESET}"
else
    echo -e " Target Test: ${YELLOW}All Tests${RESET}"
fi

# Pre-flight environment checks
echo -e "\n${BOLD}[1/3] Checking environment prerequisites...${RESET}"

if ! command -v cocotb-config &> /dev/null; then
    echo -e "${YELLOW}Warning: 'cocotb-config' not found in current PATH.${RESET}"
    echo -e "Please ensure you have activated your Python virtual environment where cocotb is installed:"
    echo -e "  ${BOLD}python3 -m venv .venv && source .venv/bin/activate && pip install -r ../verification/requirements.txt${RESET}"
    echo ""
fi

if ! command -v "${SIM_NAME}" &> /dev/null; then
    echo -e "${YELLOW}Warning: Simulator '${SIM_NAME}' not found in PATH.${RESET}"
    echo -e "Install via Homebrew (macOS) if needed:"
    echo -e "  ${BOLD}brew install verilator${RESET}   or   ${BOLD}brew install icarus-verilog${RESET}"
    echo ""
fi

# Build and execute simulation
echo -e "${BOLD}[2/3] Invoking Makefile...${RESET}"

MAKE_CMD="make SIM=${SIM_NAME}"
if [[ -n "${TESTCASE}" ]]; then
    MAKE_CMD="${MAKE_CMD} TESTCASE=${TESTCASE}"
fi

echo -e "Executing: ${BOLD}${MAKE_CMD}${RESET}\n"
${MAKE_CMD}

echo -e "\n${BOLD}[3/3] Simulation finished successfully!${RESET}"

if [[ ${OPEN_WAVES} -eq 1 ]]; then
    make waves
fi
