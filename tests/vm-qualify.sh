#!/bin/bash
# Operational qualification: verify that Home Assistant is correctly installed
# on the OpenWrt VM. Does NOT test HA's functionality — only that the installed
# Python libraries load and that HA starts and answers on port 8123.
#
# Usage: ./vm-qualify.sh [arch]
#   arch: x86_64 (default) or aarch64
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed.

set -uo pipefail

ARCH="${1:-x86_64}"
VENV_DIR="${2:-/opt/homeassistant}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vm-lib.sh
source "$SCRIPT_DIR/vm-lib.sh"
arch_config "$ARCH"
init_ssh
VENV_PYTHON="$VENV_DIR/bin/python3"
PASS=0
FAIL=0

check() {
    local description="$1"
    local command="$2"
    printf "  %-55s" "$description"
    if ssh_run "$command" >/dev/null 2>&1; then
        echo "PASS"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL"
        FAIL=$(( FAIL + 1 ))
    fi
}

check_output() {
    local description="$1"
    local command="$2"
    local expected="$3"
    printf "  %-55s" "$description"
    local output
    output=$(ssh_run "$command" 2>/dev/null)
    if echo "$output" | grep -q "$expected"; then
        echo "PASS"
        PASS=$(( PASS + 1 ))
    else
        echo "FAIL  (got: $output)"
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "=== OpenWrt VM Operational Qualification ($ARCH) ==="
echo ""

if ! check_ssh; then
    echo "ERROR: VM not reachable. Run ./vm-start.sh $ARCH first." >&2
    exit 1
fi

echo "--- Venv ---"
check "venv exists"          "test -x $VENV_PYTHON"

echo ""
echo "--- Python native library imports ---"
check "ciso8601"             "$VENV_PYTHON -c 'import ciso8601'"
check "cryptography"         "$VENV_PYTHON -c 'import cryptography'"
check "PIL (Pillow)"         "$VENV_PYTHON -c 'import PIL'"
check "bcrypt"               "$VENV_PYTHON -c 'import bcrypt'"
check "aiohttp"              "$VENV_PYTHON -c 'import aiohttp'"
check "uv"                   "$VENV_PYTHON -c 'import uv'"
check "yaml"                 "$VENV_PYTHON -c 'import yaml'"
check "sqlalchemy"           "$VENV_PYTHON -c 'import sqlalchemy'"
check "zeroconf"             "$VENV_PYTHON -c 'import zeroconf'"

echo ""
echo "--- Home Assistant package import ---"
check "homeassistant imports" "$VENV_PYTHON -c 'import homeassistant'"
check_output "HA version"    "$VENV_PYTHON -c 'from homeassistant.const import __version__; print(__version__)'" "20"

echo ""
echo "--- Home Assistant startup ---"
check "hass service starts"  "/etc/init.d/homeassistant start"

# Wait up to 90 seconds for HA to listen on port 8123.
# Check TCP port via /proc/net/tcp (hex port 1FBB = 8123); wget is not used
# because the API requires auth in HA 2026+ and returns HTTP 401.
printf "  %-55s" "port 8123 responds"
HA_UP=0
for _ in $(seq 1 30); do
    sleep 3
    if ssh_run "grep -q '1FBB' /proc/net/tcp /proc/net/tcp6 2>/dev/null" 2>/dev/null; then
        echo "PASS"
        PASS=$(( PASS + 1 ))
        HA_UP=1
        break
    fi
done
if [[ $HA_UP -eq 0 ]]; then
    echo "FAIL  (timeout)"
    FAIL=$(( FAIL + 1 ))
fi

if ssh_run "test -e /etc/init.d/hass-configurator" >/dev/null 2>&1; then
    check "hass-configurator starts"  "/etc/init.d/hass-configurator start"

    # Wait up to 30 seconds for hass-configurator to bind port 3218 (hex 0C92 = 3218).
    # The init script returns before the process has bound the socket.
    printf "  %-55s" "hass-configurator port 3218"
    HC_UP=0
    for _ in $(seq 1 10); do
        sleep 3
        if ssh_run "grep -q '0C92' /proc/net/tcp /proc/net/tcp6 2>/dev/null" 2>/dev/null; then
            echo "PASS"
            PASS=$(( PASS + 1 ))
            HC_UP=1
            break
        fi
    done
    if [[ $HC_UP -eq 0 ]]; then
        echo "FAIL  (timeout)"
        FAIL=$(( FAIL + 1 ))
    fi
else
    check "hass-configurator init script absent (disabled by default)" \
        "! test -e /etc/init.d/hass-configurator"
    check "hass-configurator port 3218 not listening" \
        "! grep -q '0C92' /proc/net/tcp /proc/net/tcp6 2>/dev/null"
fi

echo ""
echo "--- Reboot persistence ---"
check "hass init script enabled" "/etc/init.d/homeassistant enabled"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
