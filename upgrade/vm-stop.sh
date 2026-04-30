#!/bin/bash
# Stop the OpenWrt QEMU VM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/vm.pid"

if [[ ! -f "$PID_FILE" ]]; then
    echo "No PID file found; VM may not be running."
    exit 0
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
    echo "Stopping VM (PID $PID)..."
    kill "$PID"
    rm -f "$PID_FILE"
    echo "VM stopped."
else
    echo "VM process $PID not found (already stopped)."
    rm -f "$PID_FILE"
fi

# Kill any stray QEMU instances using the same image (e.g. from a previous session
# where the PID file was lost or stale).
STRAY=$(pgrep -f "qemu-system-x86_64.*$(basename "${SCRIPT_DIR}")" 2>/dev/null || true)
if [[ -n "$STRAY" ]]; then
    echo "Killing stray QEMU process(es): $STRAY"
    kill $STRAY
fi