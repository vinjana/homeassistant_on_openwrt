#!/bin/bash
# Shared library for vm-*.sh scripts.  Source this file; do not execute it directly.
#
# Caller must set SCRIPT_DIR before sourcing (used by pid_file).
# Caller must also set ARCH before calling arch_config.
#
# Typical preamble:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   ARCH="${1:-x86_64}"
#   source "$SCRIPT_DIR/vm-lib.sh"
#   arch_config "$ARCH"   # sets IMG_NAME, IMG_URL, SSH_PORT, QEMU, QEMU_EXTRA_ARGS, IMG_PATTERN
#   init_ssh               # sets SSH_OPTS (string) and SSH_ARGS (array)
#
# Globals set by arch_config:
#   IMG_NAME          base image filename (no path)
#   IMG_URL           download URL for .img.gz
#   SSH_PORT          host-side SSH port for this arch
#   QEMU              QEMU binary name
#   QEMU_EXTRA_ARGS   (array) extra arguments for the QEMU launch command
#   IMG_PATTERN       substring used by pgrep to identify a running QEMU process
#
# Globals set by init_ssh (requires SSH_PORT):
#   SSH_ARGS   (array) full ssh invocation ready for "${SSH_ARGS[@]}"

set -euo pipefail

# ---------------------------------------------------------------------------
# arch_config ARCH
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # variables are globals consumed by sourcing scripts
arch_config() {
    ARCH="$1"
    case "$ARCH" in
        x86_64)
            IMG_NAME="openwrt-25.12.3-x86-64-generic-ext4-combined.img"
            IMG_URL="https://downloads.openwrt.org/releases/25.12.3/targets/x86/64/openwrt-25.12.3-x86-64-generic-ext4-combined.img.gz"
            SSH_PORT=2222
            QEMU=qemu-system-x86_64
            QEMU_EXTRA_ARGS=(-enable-kvm)
            IMG_PATTERN="x86-64-generic-ext4-combined"
            ;;
        aarch64)
            IMG_NAME="openwrt-25.12.3-armsr-armv8-generic-ext4-combined-efi.img"
            IMG_URL="https://downloads.openwrt.org/releases/25.12.3/targets/armsr/armv8/openwrt-25.12.3-armsr-armv8-generic-ext4-combined-efi.img.gz"
            SSH_PORT=2223
            QEMU=qemu-system-aarch64
            local efi_fw=""
            for candidate in \
                /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
                /usr/share/AAVMF/AAVMF_CODE.fd \
                /usr/share/edk2/aarch64/QEMU_EFI.fd; do
                if [[ -f "$candidate" ]]; then
                    efi_fw="$candidate"
                    break
                fi
            done
            if [[ -z "$efi_fw" ]]; then
                echo "ERROR: aarch64 EFI firmware not found." >&2
                echo "Install with: sudo apt-get install qemu-efi-aarch64" >&2
                exit 1
            fi
            QEMU_EXTRA_ARGS=(-machine virt -cpu cortex-a57 -bios "$efi_fw")
            IMG_PATTERN="armsr-armv8-generic-ext4-combined-efi"
            ;;
        *)
            echo "Unknown arch '$ARCH'. Supported: x86_64, aarch64" >&2
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# init_ssh
#   Must be called after arch_config (needs SSH_PORT).
# ---------------------------------------------------------------------------
init_ssh() {
    SSH_ARGS=(
        ssh
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o ConnectTimeout=5
        -o BatchMode=yes
        root@localhost
        -p "$SSH_PORT"
    )
}

# ---------------------------------------------------------------------------
# ssh_run CMD [ARGS...]
# ---------------------------------------------------------------------------
ssh_run() {
    "${SSH_ARGS[@]}" "$@"
}

# ---------------------------------------------------------------------------
# wait_for_ssh [MAX_TRIES [INTERVAL_S]]
#   Default: 24 tries × 5 s = 120 s.  Exits 1 on timeout.
# ---------------------------------------------------------------------------
wait_for_ssh() {
    local max_tries="${1:-24}" interval="${2:-5}"
    local poll_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes)
    echo "Waiting for VM SSH (up to $((max_tries * interval)) s)..."
    for _ in $(seq 1 "$max_tries"); do
        if ssh "${poll_opts[@]}" root@localhost -p "$SSH_PORT" 'echo ok' 2>/dev/null; then
            echo "VM is ready."
            return 0
        fi
        printf "."
        sleep "$interval"
    done
    echo ""
    echo "ERROR: VM did not become reachable within $((max_tries * interval)) seconds." >&2
    return 1
}

# ---------------------------------------------------------------------------
# check_ssh
#   Returns 0 if the VM is reachable, 1 otherwise.  No output.
# ---------------------------------------------------------------------------
check_ssh() {
    "${SSH_ARGS[@]}" 'echo ok' 2>/dev/null
}

# ---------------------------------------------------------------------------
# pid_file
#   Prints the PID file path for the current $ARCH and $SCRIPT_DIR.
# ---------------------------------------------------------------------------
pid_file() {
    echo "$SCRIPT_DIR/vm-${ARCH}.pid"
}

# ---------------------------------------------------------------------------
# pid_write PID
# ---------------------------------------------------------------------------
pid_write() {
    echo "$1" > "$(pid_file)"
}

# ---------------------------------------------------------------------------
# pid_running
#   Returns 0 if the PID file exists and the process is alive.
# ---------------------------------------------------------------------------
pid_running() {
    local f
    f="$(pid_file)"
    [[ -f "$f" ]] && kill -0 "$(cat "$f")" 2>/dev/null
}

# ---------------------------------------------------------------------------
# pristine_img
#   Prints the pristine snapshot path for the current arch image.
#   Requires: IMG_NAME, SCRIPT_DIR.
# ---------------------------------------------------------------------------
pristine_img() {
    echo "$SCRIPT_DIR/${IMG_NAME%.img}.pristine.img"
}

# ---------------------------------------------------------------------------
# save_pristine
#   Copies the current image to its pristine path if no pristine exists yet.
#   No-op when the pristine already exists.
# ---------------------------------------------------------------------------
save_pristine() {
    local pristine
    pristine="$(pristine_img)"
    if [[ -f "$pristine" ]]; then
        echo "Pristine image already exists: $(basename "$pristine")"
        return 0
    fi
    echo "Saving pristine image snapshot..."
    cp "$SCRIPT_DIR/$IMG_NAME" "$pristine"
    echo "Pristine image saved: $(basename "$pristine")"
}

# ---------------------------------------------------------------------------
# restore_pristine
#   Restores the working image from the pristine snapshot.
#   Uses cp --reflink=auto for instant copy-on-write where the filesystem
#   supports it (btrfs, XFS); falls back to a plain cp on others.
#   Exits 1 if no pristine snapshot exists.
# ---------------------------------------------------------------------------
restore_pristine() {
    local pristine img
    pristine="$(pristine_img)"
    img="$SCRIPT_DIR/$IMG_NAME"
    if [[ ! -f "$pristine" ]]; then
        echo "ERROR: No pristine image found: $(basename "$pristine")" >&2
        echo "Run ./vm-setup.sh $ARCH first." >&2
        return 1
    fi
    echo "Restoring $ARCH image from pristine snapshot..."
    if cp --reflink=auto "$pristine" "$img" 2>/dev/null; then
        echo "Image restored."
    else
        cp "$pristine" "$img"
        echo "Image restored."
    fi
}

# ---------------------------------------------------------------------------
# pid_kill
#   Terminates the VM process and removes the PID file.  No-op if no PID file.
# ---------------------------------------------------------------------------
pid_kill() {
    local f pid
    f="$(pid_file)"
    [[ -f "$f" ]] || return 0
    pid=$(cat "$f")
    if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping $ARCH VM (PID $pid)..."
        kill "$pid"
        echo "VM stopped."
    else
        echo "VM process $pid not found (already stopped)."
    fi
    rm -f "$f"
}
