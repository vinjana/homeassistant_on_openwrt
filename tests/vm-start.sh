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

case "$ARCH" in
    x86_64)
        IMG="$SCRIPT_DIR/openwrt-25.12.3-x86-64-generic-ext4-combined.img"
        SSH_PORT=2222
        QEMU=qemu-system-x86_64
        QEMU_EXTRA_ARGS=(-enable-kvm)
        ;;
    aarch64)
        IMG="$SCRIPT_DIR/openwrt-25.12.3-armsr-armv8-generic-ext4-combined-efi.img"
        SSH_PORT=2223
        QEMU=qemu-system-aarch64
        # Locate the EFI firmware; path varies by distro.
        EFI_FW=""
        for candidate in \
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
            /usr/share/AAVMF/AAVMF_CODE.fd \
            /usr/share/edk2/aarch64/QEMU_EFI.fd; do
            if [[ -f "$candidate" ]]; then
                EFI_FW="$candidate"
                break
            fi
        done
        if [[ -z "$EFI_FW" ]]; then
            echo "ERROR: aarch64 EFI firmware not found." >&2
            echo "Install with: sudo apt-get install qemu-efi-aarch64" >&2
            exit 1
        fi
        QEMU_EXTRA_ARGS=(-machine virt -cpu cortex-a57 -bios "$EFI_FW")
        ;;
    *)
        echo "Unknown arch '$ARCH'. Supported: x86_64, aarch64" >&2
        exit 1
        ;;
esac

PID_FILE="$SCRIPT_DIR/vm-${ARCH}.pid"

if [[ ! -f "$IMG" ]]; then
    echo "Image not found: $IMG" >&2
    echo "Run ./vm-setup.sh $ARCH first." >&2
    exit 1
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "VM ($ARCH) already running (PID $(cat "$PID_FILE"))."
    echo "Connect via: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost -p $SSH_PORT"
    exit 0
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
echo "$VM_PID" > "$PID_FILE"
echo "VM started (PID $VM_PID)."
echo "Waiting for SSH on port $SSH_PORT..."

for i in $(seq 1 24); do
    sleep 5
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes \
            root@localhost -p "$SSH_PORT" 'echo ok' 2>/dev/null; then
        echo ""
        echo "VM is ready."
        echo "Connect: ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost -p $SSH_PORT"
        exit 0
    fi
    printf "."
done

echo ""
echo "WARNING: SSH did not become available within 120 seconds."
echo "Check VM console output or run ./vm-stop.sh $ARCH and retry."
exit 1
