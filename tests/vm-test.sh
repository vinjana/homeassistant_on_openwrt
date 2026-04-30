#!/bin/bash
# End-to-end VM test runner.  Orchestrates all test steps in order, or runs a
# single named step when --step is given.
#
# Usage: ./vm-test.sh [--step STEP] [arch] [install-script]
#   arch            x86_64 (default) or aarch64
#   install-script  path to install script (default: ../ha_install.sh)
#   --step STEP     run only one step: setup | start | run | qualify | stop | all
#
# Full run order: setup → start → run → qualify → stop
# 'setup' restores the working image from its pristine snapshot.  It does NOT
# re-download or reconfigure the image — run ./vm-setup.sh first to create the
# pristine snapshot.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────

STEP=""
if [[ "${1:-}" == "--step" ]]; then
    STEP="$2"
    shift 2
fi

ARCH="x86_64"
if [[ "${1:-}" == "x86_64" || "${1:-}" == "aarch64" ]]; then
    ARCH="$1"
    shift
fi

INSTALL_SCRIPT="${1:-$SCRIPT_DIR/../ha_install.sh}"

arch_config "$ARCH"

# ── Step functions ─────────────────────────────────────────────────────────────

do_setup() {
    restore_pristine
}

do_start() {
    "$SCRIPT_DIR/vm-start.sh" "$ARCH"
}

do_run() {
    "$SCRIPT_DIR/vm-run.sh" "$ARCH" "$INSTALL_SCRIPT"
}

do_qualify() {
    "$SCRIPT_DIR/vm-qualify.sh" "$ARCH"
}

do_stop() {
    "$SCRIPT_DIR/vm-stop.sh" "$ARCH"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

run_all() {
    trap '"$SCRIPT_DIR/vm-stop.sh" "$ARCH" || true' ERR
    echo "=== VM end-to-end test: $ARCH ==="
    do_setup
    do_start
    do_run
    do_qualify
    do_stop
    echo ""
    echo "=== Test complete: $ARCH ==="
}

if [[ -z "$STEP" || "$STEP" == "all" ]]; then
    run_all
else
    case "$STEP" in
        setup)   do_setup ;;
        start)   do_start ;;
        run)     do_run ;;
        qualify) do_qualify ;;
        stop)    do_stop ;;
        *)
            echo "Unknown step '$STEP'. Valid: setup start run qualify stop all" >&2
            exit 1
            ;;
    esac
fi
