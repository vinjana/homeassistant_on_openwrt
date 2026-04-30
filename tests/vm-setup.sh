#!/bin/bash
# One-time setup: download the OpenWrt image for the given architecture, resize it
# to 2 GB, expand the root partition, and patch the network config so that QEMU
# user-mode networking can reach the VM via SSH port-forward.
#
# Usage: ./vm-setup.sh [arch]
#   arch: x86_64 (default) or aarch64
#
# Requires: qemu-img, parted, e2fsck, resize2fs, debugfs, dd, python3, gdisk
#   For aarch64: sudo apt-get install qemu-system-arm qemu-efi-aarch64
# Does NOT require sudo — all operations work on regular files in userspace.
# Idempotent: skips steps that are already done.

set -euo pipefail

# Force C locale so parted/e2fsprogs output is in English regardless of system locale.
export LC_ALL=C

ARCH="${1:-x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"
arch_config "$ARCH"

IMG="$SCRIPT_DIR/$IMG_NAME"
IMG_GZ="${IMG}.gz"
TARGET_SIZE="2G"
TARGET_BYTES=$((2 * 1024 * 1024 * 1024))

echo "=== OpenWrt VM setup: $ARCH (SSH port $SSH_PORT) ==="

# ── Step 1: download ──────────────────────────────────────────────────────────
if [[ ! -f "$IMG" ]]; then
    if [[ ! -f "$IMG_GZ" ]]; then
        echo "Downloading OpenWrt 25.12.3 $ARCH image..."
        wget -O "$IMG_GZ" "$IMG_URL"
    else
        echo "Found existing .gz, skipping download."
    fi
    echo "Decompressing..."
    gunzip "$IMG_GZ"
else
    echo "Image already present: $IMG"
fi

# ── Step 2: resize image file to 2 GB ────────────────────────────────────────
CURRENT_SIZE=$(qemu-img info --output=json "$IMG" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['virtual-size'])")

if [[ "$CURRENT_SIZE" -lt "$TARGET_BYTES" ]]; then
    echo "Resizing image file to $TARGET_SIZE..."
    qemu-img resize -f raw "$IMG" "$TARGET_SIZE"
else
    echo "Image already at $TARGET_SIZE, skipping resize."
fi

# After resizing a GPT image the backup GPT header is stranded at the old end
# of the disk. parted cannot resize partitions until the header is relocated.
# sgdisk --move-second-header does this; it exits non-zero on MBR images, so
# we suppress the error and let parted handle MBR disks normally.
if sgdisk --move-second-header "$IMG" > /dev/null 2>&1; then
    echo "GPT backup header relocated to end of disk."
fi

# ── Step 3: expand partition 2 to fill the disk ───────────────────────────────
# parted works on regular files without root.
# Use LC_ALL=C (set above) so output is in English for reliable awk parsing.
PART2_END=$(parted -s "$IMG" unit s print | awk '/^ 2 / {gsub("s",""); print $3}')
DISK_END=$(parted  -s "$IMG" unit s print | awk '/^Disk.*:/ {gsub("s",""); print $3}')

echo "Disk end: ${DISK_END}s  Partition 2 end: ${PART2_END}s"

if [[ "$PART2_END" -lt $(( DISK_END - 2 )) ]]; then
    echo "Expanding partition 2 to fill the disk..."
    parted -s "$IMG" resizepart 2 100%
    echo "Partition 2 expanded."
    # Refresh values after resize
    PART2_END=$(parted -s "$IMG" unit s print | awk '/^ 2 / {gsub("s",""); print $3}')
else
    echo "Partition 2 already fills the disk, skipping."
fi

PART2_START=$(parted -s "$IMG" unit s print | awk '/^ 2 / {gsub("s",""); print $2}')
PART2_COUNT=$(( PART2_END - PART2_START + 1 ))
echo "Partition 2: sectors ${PART2_START}–${PART2_END} (${PART2_COUNT} sectors)"

# ── Step 4: expand the ext4 filesystem to fill partition 2 ───────────────────
# resize2fs on this system does not support -o (byte-offset mode).
# Workaround: dd-extract the partition to a temp file, resize the filesystem
# there, then dd it back. No root or loop device needed.

TMPPART=$(mktemp "$SCRIPT_DIR/partition2.XXXXXX.img")
trap 'rm -f "$TMPPART"' EXIT

echo "Extracting partition 2 to temp file (${PART2_COUNT} sectors)..."
dd if="$IMG" of="$TMPPART" bs=512 skip="$PART2_START" count="$PART2_COUNT" status=none

# Check if the filesystem already fills the partition.
FS_BLOCKS=$(dumpe2fs -h "$TMPPART" 2>/dev/null | awk '/^Block count:/ {print $3}')
FS_BLOCK_SIZE=$(dumpe2fs -h "$TMPPART" 2>/dev/null | awk '/^Block size:/ {print $3}')
FS_BYTES=$(( FS_BLOCKS * FS_BLOCK_SIZE ))
PART_BYTES=$(( PART2_COUNT * 512 ))

echo "Filesystem: ${FS_BYTES} bytes  Partition: ${PART_BYTES} bytes"

if [[ "$FS_BYTES" -lt $(( PART_BYTES - 1024 * 1024 )) ]]; then
    echo "Expanding ext4 filesystem..."
    e2fsck -f -y "$TMPPART" || true
    resize2fs "$TMPPART"
    echo "Writing expanded filesystem back to image..."
    dd if="$TMPPART" of="$IMG" bs=512 seek="$PART2_START" count="$PART2_COUNT" conv=notrunc status=none
    echo "Filesystem expanded."
else
    echo "Filesystem already fills partition, skipping."
fi

# ── Step 5: inject uci-defaults script for QEMU SSH networking ───────────────
#
# Goal: make the VM reachable via SSH on host port $SSH_PORT using QEMU's
# user-mode (SLIRP) networking with a hostfwd tcp::${SSH_PORT}->:22 rule.
#
# Why not patch /etc/config/network directly?
#   We tried writing a DHCP config to /etc/config/network via debugfs before
#   first boot. It appeared to work (debugfs reported success), but OpenWrt's
#   boot initialisation regenerated the file from its own defaults, overwriting
#   the patch. The /etc/config/ tree is managed by OpenWrt's uci system and
#   must be modified through that API to persist correctly.
#
# Why uci-defaults?
#   /etc/uci-defaults/ is OpenWrt's standard mechanism for first-boot
#   configuration. Scripts there are executed once during boot (by
#   /etc/init.d/boot via /lib/functions/boot.sh), run *after* the default
#   network init, and are then deleted. They call uci to set values through
#   the proper API so changes survive the boot sequence.
#
# Why a second NIC (eth1) instead of changing eth0?
#   eth0 is part of br-lan (the default LAN bridge at 192.168.1.1) by
#   OpenWrt's factory config. Repurposing it for DHCP would break the LAN
#   setup and is harder to make idempotent. A second NIC (eth1) is invisible
#   to OpenWrt's default config, so we can configure it freely without
#   touching the existing LAN/firewall setup.
#
# NIC assignment in QEMU (see vm-start.sh):
#   NIC 1 (eth0) → first -nic argument  → br-lan, 192.168.1.1, untouched
#   NIC 2 (eth1) → second -nic argument, hostfwd tcp::${SSH_PORT}->:22 → DHCP
#
# The uci-defaults script configures eth1 as a DHCP interface named 'qemu'
# and adds it to the LAN firewall zone, which allows incoming SSH.

echo "Extracting partition 2 to check/inject uci-defaults..."
dd if="$IMG" of="$TMPPART" bs=512 skip="$PART2_START" count="$PART2_COUNT" status=none

EXISTING=$(debugfs -R "cat /etc/uci-defaults/99-qemu-ssh" "$TMPPART" 2>/dev/null || true)
if echo "$EXISTING" | grep -q "qemu"; then
    echo "uci-defaults script already present, skipping."
else
    echo "Injecting /etc/uci-defaults/99-qemu-ssh..."

    UCISCRIPT=$(mktemp)
    trap 'rm -f "$TMPPART" "$UCISCRIPT"' EXIT
    cat > "$UCISCRIPT" <<'UCIEOF'
#!/bin/sh
# Configure eth1 (QEMU second NIC) for DHCP and place it in the LAN firewall
# zone so that SSH is reachable from the host via the hostfwd port-forward.
uci set network.qemu=interface
uci set network.qemu.device=eth1
uci set network.qemu.proto=dhcp
uci commit network
uci add_list firewall.@zone[0].network=qemu
uci commit firewall
UCIEOF

    debugfs -w "$TMPPART" -R "write $UCISCRIPT /etc/uci-defaults/99-qemu-ssh" 2>/dev/null
    # Mark executable so /lib/functions/boot.sh will run it.
    debugfs -w "$TMPPART" -R "set_inode_field /etc/uci-defaults/99-qemu-ssh i_mode 0100755" 2>/dev/null
    # debugfs bypasses normal VFS bookkeeping and can leave stale directory
    # entries; e2fsck repairs any inconsistencies before the partition is
    # written back.
    e2fsck -f -y "$TMPPART" >/dev/null 2>&1 || true
    echo "Writing partition back to image..."
    dd if="$TMPPART" of="$IMG" bs=512 seek="$PART2_START" count="$PART2_COUNT" conv=notrunc status=none
    echo "uci-defaults script injected."
fi

# ── Step 6: snapshot pristine image ──────────────────────────────────────────
save_pristine

echo ""
echo "Setup complete. Run ./vm-start.sh $ARCH to boot the VM."
