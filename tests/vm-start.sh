#!/bin/bash
# Start the OpenWrt QEMU VM in the background.
# SSH is forwarded: host port 2222 (x86_64) or 2223 (aarch64) → VM port 22.
# Waits up to 120 seconds for SSH to become available.
#
# Usage: ./vm-start.sh [arch]
#   arch: x86_64 (default) or aarch64
#
# Requires:
#   x86_64:  qemu-system-x86_64 with KVM support
#   aarch64: qemu-system-aarch64 + qemu-efi-aarch64 (sudo apt-get install qemu-system-arm qemu-efi-aarch64)

set -euo pipefail

ARCH="${1:-x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"
arch_config "$ARCH"
IMG="$SCRIPT_DIR/$IMG_NAME"

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    echo "Run ./vm-setup.sh $ARCH first." >&2
    exit 1
fi

if pid_running; then
    echo "ERROR: VM ($ARCH) already running (PID $(cat "$(pid_file)"))." >&2
    echo "Stop it first: ./vm-stop.sh $ARCH" >&2
    exit 1
fi

echo "Starting OpenWrt $ARCH VM..."
# Two NICs are required for SSH access from the host:
#
# NIC 1 (eth0): plain user-mode network, no port-forward.
#   OpenWrt's default config assigns eth0 to br-lan (192.168.1.1).
#   We leave this untouched so the LAN/firewall setup remains intact.
#
# NIC 2 (eth1): user-mode network with hostfwd tcp::${SSH_PORT}->:22.
#   OpenWrt's factory config does not reference eth1, so it is free for us
#   to configure. vm-setup.sh injects a uci-defaults script that assigns
#   eth1 to a DHCP interface in the LAN firewall zone on first boot.
#   QEMU's built-in DHCP server gives it 10.0.2.15, and the hostfwd rule
#   forwards host:${SSH_PORT} to VM:22, making SSH reachable.
"$QEMU" \
    -m 1024 \
    -smp 2 \
    "${QEMU_EXTRA_ARGS[@]}" \
    -drive file="$IMG",if=virtio,format=raw \
    -nic user,model=virtio \
    -nic user,model=virtio,hostfwd=tcp::${SSH_PORT}-:22 \
    -nographic \
    -serial mon:null \
    -monitor none \
    2>/dev/null &

VM_PID=$!
pid_write "$VM_PID"
echo "VM started (PID $VM_PID)."

# shellcheck disable=SC2119
if wait_for_ssh; then
    echo "Connect: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost -p $SSH_PORT"
else
    echo "Check VM console output or run ./vm-stop.sh $ARCH and retry." >&2
    exit 1
fi
