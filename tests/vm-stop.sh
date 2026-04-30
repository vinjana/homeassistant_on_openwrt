#!/bin/bash
# Stop the OpenWrt QEMU VM.
#
# Usage: ./vm-stop.sh [arch]
#   arch: x86_64 (default) or aarch64

set -euo pipefail

ARCH="${1:-x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"
arch_config "$ARCH"

pid_kill

# Kill any stray QEMU instances using the same image.
if [[ -n "$IMG_PATTERN" ]]; then
    if pkill -f "qemu.*$IMG_PATTERN" 2>/dev/null; then
        echo "Killed stray QEMU process(es) matching $IMG_PATTERN."
    fi
fi
