#!/bin/bash
# End-to-end VM test runner.  Orchestrates all test steps in order, or runs a
# single named step when --step is given.
#
# Usage: ./vm-test.sh [--step STEP] [arch] [install-script] [-- install-args...]
#   arch            x86_64 (default) or aarch64
#   install-script  path to install script (default: ../ha_install.sh)
#   install-args    forwarded to ha_install.sh, e.g. --venv-dir /srv/ha --with-configurator;
#                   the venv path for qualification is taken from --venv-dir
#   --step STEP     run only one step: setup | start | run | qualify | rerun | reboot | stop | all
#
# Full run order: setup → start → run → qualify → rerun → qualify → reboot → stop
#   rerun   runs the install script a second time over the existing installation
#           (the documented upgrade path) and qualifies again
#   reboot  reboots the VM and checks that HA starts on its own (init script enabled)
# 'setup' restores the working image from its pristine snapshot.  It does NOT
# re-download or reconfigure the image — run ./vm-setup.sh first to create the
# pristine snapshot.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"

# ── Argument parsing ───────────────────────────────────────────────────────────

STEP=""
if [[ "${1:-}" == "--step" ]]; then
    STEP="${2:?--step needs a value}"
    shift 2
fi

ARCH="x86_64"
if [[ "${1:-}" == "x86_64" || "${1:-}" == "aarch64" ]]; then
    ARCH="$1"
    shift
fi

INSTALL_SCRIPT="$SCRIPT_DIR/../ha_install.sh"
if [[ -n "${1:-}" && "${1:-}" != "--" ]]; then
    INSTALL_SCRIPT="$1"
    shift
fi
if [[ "${1:-}" == "--" ]]; then
    shift
fi
INSTALL_ARGS=("$@")

venv_dir_from_args() {
    local venv="/opt/homeassistant"
    local i
    for (( i = 0; i < ${#INSTALL_ARGS[@]}; i++ )); do
        case "${INSTALL_ARGS[i]}" in
            --venv-dir)   venv="${INSTALL_ARGS[i+1]:?--venv-dir needs a value}" ;;
            --venv-dir=*) venv="${INSTALL_ARGS[i]#*=}" ;;
        esac
    done
    echo "$venv"
}
VENV_DIR="$(venv_dir_from_args)"

arch_config "$ARCH"
init_ssh

# ── Step functions ─────────────────────────────────────────────────────────────

do_setup() {
    restore_pristine
}

do_start() {
    "$SCRIPT_DIR/vm-start.sh" "$ARCH"
}

# The install script requires non-default directories to exist (as on a mounted disk).
make_target_dirs() {
    local i dirs=()
    for (( i = 0; i < ${#INSTALL_ARGS[@]}; i++ )); do
        case "${INSTALL_ARGS[i]}" in
            --tmp-dir|--venv-dir|--config-dir) dirs+=("${INSTALL_ARGS[i+1]:-}") ;;
            --tmp-dir=*|--venv-dir=*|--config-dir=*) dirs+=("${INSTALL_ARGS[i]#*=}") ;;
        esac
    done
    if (( ${#dirs[@]} > 0 )); then
        ssh_run mkdir -p "${dirs[@]}"
    fi
}

do_run() {
    make_target_dirs
    "$SCRIPT_DIR/vm-run.sh" "$ARCH" "$INSTALL_SCRIPT" -- "${INSTALL_ARGS[@]}"
}

do_qualify() {
    "$SCRIPT_DIR/vm-qualify.sh" "$ARCH" "$VENV_DIR"
}

do_rerun() {
    # The install script refuses to run while HA is running; qualify started it.
    # procd only signals HA to stop; it takes a few seconds to exit.
    # "[b]in/hass" keeps pgrep from matching this remote shell, whose command line contains the pattern.
    # shellcheck disable=SC2016  # expanded by the VM's shell, not here
    ssh_run '/etc/init.d/homeassistant stop; /etc/init.d/hass-configurator stop 2>/dev/null
             for _ in $(seq 1 30); do pgrep -f "[b]in/hass" >/dev/null || exit 0; sleep 2; done
             echo "ERROR: HA still running 60 s after stop" >&2; exit 1'
    echo "--- Second install run over the existing installation ---"
    do_run
}

do_reboot() {
    echo "--- Reboot: HA must start on its own ---"
    ssh_run 'reboot' || true
    sleep 15
    wait_for_ssh 36 5
    # Port 8123 = hex 1FBB in /proc/net/tcp; HA is slow to bind after boot.
    local _
    for _ in $(seq 1 60); do
        if ssh_run "grep -q '1FBB' /proc/net/tcp /proc/net/tcp6 2>/dev/null"; then
            echo "HA answers on port 8123 after reboot."
            return 0
        fi
        sleep 5
    done
    echo "ERROR: HA did not listen on port 8123 within 300 s after reboot." >&2
    exit "$EXIT_CHECKS_FAILED"
}

do_stop() {
    "$SCRIPT_DIR/vm-stop.sh" "$ARCH"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

run_all() {
    trap '"$SCRIPT_DIR/vm-stop.sh" "$ARCH" || true' ERR
    echo "=== VM end-to-end test: $ARCH${INSTALL_ARGS[*]:+ (install args: ${INSTALL_ARGS[*]})} ==="
    do_setup
    do_start
    do_run
    do_qualify
    do_rerun
    do_qualify
    do_reboot
    do_stop
    echo ""
    echo "=== Test complete: $ARCH ==="
}

if [[ -z "$STEP" || "$STEP" == "all" ]]; then
    run_all
else
    case "$STEP" in
        setup)   do_setup ;;
        start)   do_start ;;
        run)     do_run ;;
        qualify) do_qualify ;;
        rerun)   do_rerun ;;
        reboot)  do_reboot ;;
        stop)    do_stop ;;
        *)
            echo "Unknown step '$STEP'. Valid: setup start run qualify rerun reboot stop all" >&2
            exit "$EXIT_USAGE"
            ;;
    esac
fi
