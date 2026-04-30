#!/bin/bash
# Stop the OpenWrt QEMU VM.
#
# Usage: ./vm-stop.sh [arch]
#   arch: x86_64 (default) or aarch64

set -euo pipefail

ARCH="${1:-x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/vm-${ARCH}.pid"

if [[ ! -f "$PID_FILE" ]]; then
    echo "No PID file found for $ARCH; VM may not be running."
    exit 0
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
    echo "Stopping $ARCH VM (PID $PID)..."
    kill "$PID"
    rm -f "$PID_FILE"
    echo "VM stopped."
else
    echo "VM process $PID not found (already stopped)."
    rm -f "$PID_FILE"
fi

# Kill any stray QEMU instances using the same image.
case "$ARCH" in
    x86_64) IMG_PATTERN="x86-64-generic-ext4-combined" ;;
    aarch64) IMG_PATTERN="armsr-armv8-generic-ext4-combined-efi" ;;
    *) IMG_PATTERN="" ;;
esac

if [[ -n "$IMG_PATTERN" ]]; then
    STRAY=$(pgrep -f "qemu.*$IMG_PATTERN" 2>/dev/null || true)
    if [[ -n "$STRAY" ]]; then
        echo "Killing stray QEMU process(es): $STRAY"
        kill $STRAY
    fi
fi
