#!/bin/bash
# Deploy and run ha_install.sh on the OpenWrt VM via SSH pipe.
# Usage: ./vm-run.sh [path/to/script.sh]
# Default script: ../ha_install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="${1:-$SCRIPT_DIR/../ha_install.sh}"
SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "Install script not found: $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! ssh $SSH_OPTS root@localhost -p "$SSH_PORT" 'echo ok' 2>/dev/null; then
    echo "VM is not reachable. Run ./vm-start.sh first." >&2
    exit 1
fi

echo "Running $(basename "$INSTALL_SCRIPT") on VM..."
ssh $SSH_OPTS root@localhost -p "$SSH_PORT" 'bash -s' < "$INSTALL_SCRIPT"