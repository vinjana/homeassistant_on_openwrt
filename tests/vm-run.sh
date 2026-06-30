#!/bin/bash
# Deploy and run ha_install.sh on the OpenWrt VM via SSH pipe.
#
# Usage: ./vm-run.sh [arch] [path/to/script.sh] [-- install-script-args...]
#   arch:   x86_64 (default) or aarch64
#   script: default is ../ha_install.sh
#   install-script-args: forwarded verbatim to ha_install.sh on the VM,
#                        e.g. --with-configurator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse optional arch argument (first arg, if it looks like an arch name).
ARCH="x86_64"
if [[ "${1:-}" == "x86_64" || "${1:-}" == "aarch64" ]]; then
    ARCH="$1"
    shift
fi

INSTALL_SCRIPT="$SCRIPT_DIR/../ha_install.sh"
if [[ "${1:-}" != "--" && -n "${1:-}" ]]; then
    INSTALL_SCRIPT="$1"
    shift
fi
if [[ "${1:-}" == "--" ]]; then
    shift
fi

# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"
arch_config "$ARCH"
init_ssh

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "Install script not found: $INSTALL_SCRIPT" >&2
    exit 1
fi

if ! check_ssh; then
    echo "VM ($ARCH) is not reachable. Run ./vm-start.sh $ARCH first." >&2
    exit 1
fi

wait_for_internet

echo "Running $(basename "$INSTALL_SCRIPT") on $ARCH VM${*:+ with args: $*}..."
ssh_run 'sh -s --' "$@" < "$INSTALL_SCRIPT"
