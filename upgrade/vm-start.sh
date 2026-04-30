#!/bin/bash
# Start the OpenWrt 25.12.3 x86_64 QEMU VM in the background.
# SSH is forwarded: host port 2222 → VM port 22.
# Waits up to 60 seconds for SSH to become available.
#
# Requires: qemu-system-x86_64 with KVM support

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="$SCRIPT_DIR/openwrt-25.12.3-x86-64-generic-ext4-combined.img"
PID_FILE="$SCRIPT_DIR/vm.pid"
SSH_PORT=2222

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    echo "Run ./vm-setup.sh first." >&2
    exit 1
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "VM already running (PID $(cat "$PID_FILE"))."
    echo "Connect via: ssh -o StrictHostKeyChecking=no root@localhost -p $SSH_PORT"
    exit 0
fi

echo "Starting OpenWrt VM..."
# Two NICs are required for SSH access from the host:
#
# NIC 1 (eth0): plain user-mode network, no port-forward.
#   OpenWrt's default config assigns eth0 to br-lan (192.168.1.1).
#   We leave this untouched so the LAN/firewall setup remains intact.
#
# NIC 2 (eth1): user-mode network with hostfwd tcp::2222->:22.
#   OpenWrt's factory config does not reference eth1, so it is free for us
#   to configure. vm-setup.sh injects a uci-defaults script that assigns
#   eth1 to a DHCP interface in the LAN firewall zone on first boot.
#   QEMU's built-in DHCP server gives it 10.0.2.15, and the hostfwd rule
#   forwards host:2222 to VM:22, making SSH reachable.
qemu-system-x86_64 \
    -m 1024 \
    -smp 2 \
    -enable-kvm \
    -drive file="$IMG",if=virtio,format=raw \
    -nic user,model=virtio \
    -nic user,model=virtio,hostfwd=tcp::${SSH_PORT}-:22 \
    -nographic \
    -serial mon:null \
    -monitor none \
    2>/dev/null &

VM_PID=$!
echo "$VM_PID" > "$PID_FILE"
echo "VM started (PID $VM_PID)."
echo "Waiting for SSH on port $SSH_PORT..."

for i in $(seq 1 24); do
    sleep 5
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
            root@localhost -p "$SSH_PORT" 'echo ok' 2>/dev/null; then
        echo ""
        echo "VM is ready."
        echo "Connect: ssh -o StrictHostKeyChecking=no root@localhost -p $SSH_PORT"
        exit 0
    fi
    printf "."
done

echo ""
echo "WARNING: SSH did not become available within 120 seconds."
echo "Check VM console output or run ./vm-stop.sh and retry."
exit 1