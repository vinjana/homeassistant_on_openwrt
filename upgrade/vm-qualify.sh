#!/bin/bash
# Operational qualification: verify that Home Assistant is correctly installed
# on the OpenWrt VM. Does NOT test HA's functionality — only that the installed
# Python libraries load and that HA starts and answers on port 8123.
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed.

set -uo pipefail

SSH_PORT=2222
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
SSH="ssh $SSH_OPTS root@localhost -p $SSH_PORT"
PASS=0
FAIL=0

check() {
    local description="$1"
    local command="$2"
    printf "  %-55s" "$description"
    if $SSH "$command" >/dev/null 2>&1; then
        echo "PASS"
        (( PASS++ )) || true
    else
        echo "FAIL"
        (( FAIL++ )) || true
    fi
}

check_output() {
    local description="$1"
    local command="$2"
    local expected="$3"
    printf "  %-55s" "$description"
    local output
    output=$($SSH "$command" 2>/dev/null)
    if echo "$output" | grep -q "$expected"; then
        echo "PASS"
        (( PASS++ )) || true
    else
        echo "FAIL  (got: $output)"
        (( FAIL++ )) || true
    fi
}

echo "=== OpenWrt VM Operational Qualification ==="
echo ""

if ! $SSH 'echo ok' 2>/dev/null; then
    echo "ERROR: VM not reachable. Run ./vm-start.sh first." >&2
    exit 1
fi

echo "--- Python native library imports ---"
check "ciso8601"             "python3 -c 'import ciso8601'"
check "cryptography"         "python3 -c 'import cryptography'"
check "PIL (Pillow)"         "python3 -c 'import PIL'"
check "bcrypt"               "python3 -c 'import bcrypt'"
check "aiohttp"              "python3 -c 'import aiohttp'"
check "uv"                   "python3 -c 'import uv'"
check "yaml"                 "python3 -c 'import yaml'"
check "sqlalchemy"           "python3 -c 'import sqlalchemy'"
check "zeroconf"             "python3 -c 'import zeroconf'"

echo ""
echo "--- Home Assistant package import ---"
check "homeassistant imports" "python3 -c 'import homeassistant'"
check_output "HA version"    "python3 -c 'import homeassistant; print(homeassistant.__version__)'" "20"

echo ""
echo "--- Home Assistant startup ---"
check "hass service starts"  "/etc/init.d/homeassistant start"

# Wait up to 30 seconds for HA to answer on port 8123
printf "  %-55s" "port 8123 responds"
for i in $(seq 1 10); do
    sleep 3
    if $SSH "curl -s http://localhost:8123/api/ | grep -q version" 2>/dev/null; then
        echo "PASS"
        (( PASS++ )) || true
        break
    fi
    if [[ $i -eq 10 ]]; then
        echo "FAIL  (timeout)"
        (( FAIL++ )) || true
    fi
done

check "hass-configurator port 3218" "curl -s http://localhost:3218/ | grep -q html"

echo ""
echo "--- Reboot persistence ---"
check "hass init script enabled" "/etc/init.d/homeassistant enabled"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]