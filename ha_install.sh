#!/bin/sh
# shellcheck shell=dash
# Homeassistant installer script by @devbis

# Exit codes of this script; any other non-zero code comes from a failed command
# (set -e). Documented in --help and README.md.
EXIT_USAGE=10         # unknown option or missing option value
EXIT_HA_RUNNING=11    # Home Assistant (or HASS Configurator) is still running
EXIT_NO_SPACE=12      # not enough free disk space
EXIT_NO_VERSION=13    # no Home Assistant release found for HOMEASSISTANT_MAJOR_VERSION
EXIT_UNSAFE_PATH=14   # a path option is not an absolute path of safe characters
EXIT_NO_TARGET=15     # a non-default directory does not exist (external disk not mounted?)
EXIT_PATCH=16         # a patch of the Home Assistant source did not apply

get_ha_version()
{
  # An empty result is handled by the caller; `|| true` keeps pipefail from aborting first.
  wget -q -O- https://pypi.org/simple/homeassistant/ | grep "$HOMEASSISTANT_MAJOR_VERSION" | tail -n 1 | sed -n 's/.*homeassistant-\([0-9.ab]*\)\..*/\1/p' || true
}

get_python_version()
{
  # apk list output: "python3-base-3.13.9-r3 x86_64 ..." — extract major.minor
  # sed targets the package name prefix directly to avoid matching other
  # version-like strings (e.g. license identifiers) elsewhere on the line.
  apk list python3-base 2>/dev/null | sed -n 's/^python3-base-\([0-9]*\.[0-9]*\)\.[0-9].*/\1/p' | tail -n 1
}

get_version()
{
  local pkg="${1:?package name}"
  # No match yields an empty version; pip then reports the unpinned package.
  grep -i -m 1 "${pkg}[<=>]=" "$STORAGE_TMP/ha_requirements.txt" | sed 's/.*[<=>]=\(.*\)/\1/g' || true
}

version()
{
  local pkg="${1:?package name}"
  echo "$pkg==$(get_version "$pkg")"
}

# Both print the board name, or nothing on other hardware.
is_lumi_gateway()
{
  grep -E '(dgnwg05lm|zhwg11lm)' /etc/board.json | tr -s '"' | cut -d\" -f4 || true
}

is_gtw360()
{
  grep 'gtw360' /etc/board.json | tr -s '"' | cut -d\" -f4 || true
}

int_version() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

# A patch that changes nothing means its pattern no longer matches the Home Assistant
# source, e.g. after a version bump. The install would still succeed, with the integration
# broken (e.g. ZHA). So it aborts; HA_PATCH_CHECK=warn only lists such patches, which is
# meant for porting to a new HA version.
patch_failed()
{
  local f="${1:?patched file}"
  local what="${2:?patch}"
  if [ "${HA_PATCH_CHECK:-abort}" = warn ]; then
    echo "WARNING: patch did not change $f: $what" >&2
  else
    echo "ERROR: patch did not apply to $f: $what" >&2
    echo "       The Home Assistant source no longer matches this installer." >&2
    exit "$EXIT_PATCH"
  fi
}

# sed in place, one expression at a time; each one must change the file.
# Usage: spatch [-E] file expression...
spatch()
{
  local ere=""
  if [ "$1" = -E ]; then ere=1; shift; fi
  local f="${1:?file to patch}"; shift
  local expr before
  for expr in "$@"; do
    before=$(md5sum < "$f")
    if [ "$ere" ]; then
      sed -i -E -e "$expr" "$f"
    else
      sed -i -e "$expr" "$f"
    fi
    [ "$(md5sum < "$f")" != "$before" ] || patch_failed "$f" "$expr"
  done
}

# Replaces the exact (multi-line) text $2 with $3 in file $1; the text must be there.
replace_text()
{
  local f="${1:?file to patch}"
  python3 -c '
import sys
f, old, new = sys.argv[1:]
with open(f) as fp: s = fp.read()
if old not in s: sys.exit(1)
with open(f, "w") as fp: fp.write(s.replace(old, new))
' "$f" "${2:?text to replace}" "${3?replacement}" || patch_failed "$f" "replace: $(echo "$2" | sed -n 1p)"
}

mlpatch()
{
  # Multi-line sed in place: temporarily replaces newlines with \x01 (ASCII SOH;
  # never appears in Python source files) so that multi-line patterns can be
  # expressed as ordinary sed expressions.  Use \x01 in sed patterns wherever a
  # newline should be matched. Not in replacements: busybox sed writes a literal
  # "x01" there; use replace_text for multi-line replacements.  The file must change, as with spatch.
  local f="${1:?file to patch}"; shift
  local before
  before=$(md5sum < "$f")
  tr '\n' '\x01' < "$f" | sed "$@" | tr '\x01' '\n' > "${f}.new" && mv "${f}.new" "$f"
  [ "$(md5sum < "$f")" != "$before" ] || patch_failed "$f" "$*"
}

check_free_space()
{
  local path="${1:?directory to check}"
  local min_kb="${2:?required free space in KiB}"
  # Space this run frees on the same filesystem before it needs it (an old venv).
  local reclaim_kb="${3:-0}"
  local free_kb
  mkdir -p "$path"
  free_kb=$(df -kP "$path" | awk 'NR==2 {print $4}')
  free_kb=$((free_kb + reclaim_kb))
  if [ "$free_kb" -lt "$min_kb" ]; then
    printf "ERROR: Not enough free space at %s: %d MB available, %d MB required.\n" \
      "$path" "$((free_kb / 1024))" "$((min_kb / 1024))" >&2
    exit "$EXIT_NO_SPACE"
  fi
}

mount_point_of()
{
  local path="${1:?existing path}"
  df -kP "$path" | awk 'NR==2 {print $6}'
}

# A non-default directory must exist already. When the external disk it lives on is not
# mounted, `mkdir -p` would otherwise silently put the installation on internal flash.
require_existing_dir()
{
  local option="${1:?option name}"
  local dir="${2:?directory}"
  local default="${3:?default directory}"
  if [ "$dir" != "$default" ] && [ ! -d "$dir" ]; then
    echo "ERROR: $option directory $dir does not exist." >&2
    echo "       If it is on an external disk, mount the disk. For a new installation, create it first: mkdir -p $dir" >&2
    exit "$EXIT_NO_TARGET"
  fi
}

# Path options end up in `rm -rf`, generated init scripts and YAML, so only
# absolute paths of plain characters (no whitespace, quotes or `$`) are accepted.
require_safe_path()
{
  local option="${1:?option name}"
  local path="${2?path value}"
  case "$path" in
    /|*[!A-Za-z0-9._/+-]*|[!/]*|"")
      echo "ERROR: $option must be an absolute path other than / using only A-Z a-z 0-9 . _ / + - (got: '$path')" >&2
      exit "$EXIT_UNSAFE_PATH"
      ;;
  esac
}

set -eu
# pipefail makes a failed download inside a pipeline stop the install. busybox ash (OpenWrt)
# supports it; enable it only where available, because `set` aborts the shell otherwise.
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

HOMEASSISTANT_MAJOR_VERSION="2026.2"
# oom_score_adj for hass (-1000..1000); higher means killed first when memory runs out.
HA_OOM_SCORE_ADJ=800
export PIP_DEFAULT_TIMEOUT=100

# May be set externally to skip numpy on broken platforms (e.g. soft-float MIPS).
BROKEN_NUMPY="${BROKEN_NUMPY:-}"

# Precedence for the options below: command-line option, environment variable, the
# existing installation (venv, config, log file, configurator; see "Options not given"
# further down), default. An empty value means "not given yet".

# All temp files go here; exported as TMPDIR so pip and subprocesses use it too.
# Default is flash-backed /root/tmp-ha; override via HA_TMP_DIR or --tmp-dir.
DEFAULT_TMP=/root/tmp-ha
STORAGE_TMP="${HA_TMP_DIR:-}"

# Python venv for HA; override via HA_VENV_DIR or --venv-dir.
# Point at an external mount to keep HA packages off the internal flash.
DEFAULT_VENV=/opt/homeassistant
VENV="${HA_VENV_DIR:-}"

# HA config/data directory; override via HA_CONFIG_DIR or --config-dir.
# Holds .storage and backups, which grow over time; point at an external mount to keep
# them off internal flash (e.g. /mnt/external/homeassistant).
# The recorder database is not here; its location is set by --db-url.
DEFAULT_CONFIG=/etc/homeassistant
HA_CONFIG="${HA_CONFIG_DIR:-}"

# HA log file path; override via HA_LOG_FILE or --log-file.
DEFAULT_LOG_FILE=/var/log/home-assistant.log
HA_LOG_FILE="${HA_LOG_FILE:-}"

# recorder DB URL; override via HA_DB_URL or --db-url.
# Default lives on tmpfs (/tmp) so flash isn't worn down by constant writes,
# but history is lost on reboot. Point at a persistent path to keep history.
HA_DB_URL="${HA_DB_URL:-sqlite:////tmp/homeassistant.db}"

# Install HASS Configurator, an unauthenticated web-based file editor on port
# 3218; override via HA_INSTALL_CONFIGURATOR=1 or --with-configurator.
# Disabled by default: it's extra install time/RAM and an unauthenticated
# editor exposed on the network.
# 1 = install, 0 = do not install (and remove an earlier one), empty = not given yet.
HA_INSTALL_CONFIGURATOR="${HA_INSTALL_CONFIGURATOR:+1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tmp-dir)
      [ $# -ge 2 ] || { echo "ERROR: --tmp-dir needs a value" >&2; exit "$EXIT_USAGE"; }
      STORAGE_TMP="$2"
      shift 2
      ;;
    --tmp-dir=*)
      STORAGE_TMP="${1#*=}"
      shift
      ;;
    --venv-dir)
      [ $# -ge 2 ] || { echo "ERROR: --venv-dir needs a value" >&2; exit "$EXIT_USAGE"; }
      VENV="$2"
      shift 2
      ;;
    --venv-dir=*)
      VENV="${1#*=}"
      shift
      ;;
    --config-dir)
      [ $# -ge 2 ] || { echo "ERROR: --config-dir needs a value" >&2; exit "$EXIT_USAGE"; }
      HA_CONFIG="$2"
      shift 2
      ;;
    --config-dir=*)
      HA_CONFIG="${1#*=}"
      shift
      ;;
    --log-file)
      [ $# -ge 2 ] || { echo "ERROR: --log-file needs a value" >&2; exit "$EXIT_USAGE"; }
      HA_LOG_FILE="$2"
      shift 2
      ;;
    --log-file=*)
      HA_LOG_FILE="${1#*=}"
      shift
      ;;
    --db-url)
      [ $# -ge 2 ] || { echo "ERROR: --db-url needs a value" >&2; exit "$EXIT_USAGE"; }
      HA_DB_URL="$2"
      shift 2
      ;;
    --db-url=*)
      HA_DB_URL="${1#*=}"
      shift
      ;;
    --with-configurator)
      HA_INSTALL_CONFIGURATOR=1
      shift
      ;;
    --no-configurator)
      HA_INSTALL_CONFIGURATOR=0
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--tmp-dir <path>] [--venv-dir <path>] [--config-dir <path>] [--log-file <path>] [--db-url <url>] [--with-configurator|--no-configurator]"
      echo ""
      echo "Options:"
      echo "  Non-default directories for --tmp-dir, --venv-dir and --config-dir, and the directory"
      echo "  of a non-default --log-file, must already exist."
      echo "  When --venv-dir, --config-dir, --log-file or the configurator choice are not given,"
      echo "  they are taken from an existing installation (/etc/init.d/homeassistant), else the default."
      echo ""
      echo "  --tmp-dir <path>    Temporary build directory (default: /root/tmp-ha)"
      echo "                      Can also be set via the HA_TMP_DIR environment variable."
      echo "                      Use a path on an external mount to avoid filling the primary disk."
      echo "                      The script works in a new ha-install.* subdirectory and deletes only that."
      echo "  --venv-dir <path>   Python virtual environment directory (default: /opt/homeassistant)"
      echo "                      Can also be set via the HA_VENV_DIR environment variable."
      echo "                      Point at an external mount to keep HA packages off internal flash."
      echo "                      An existing venv there is replaced on every run."
      echo "  --config-dir <path> HA configuration and data directory (default: /etc/homeassistant)"
      echo "                      Can also be set via the HA_CONFIG_DIR environment variable."
      echo "                      Point at an external mount so .storage and backups do not fill internal flash."
      echo "                      The recorder database is not stored here; see --db-url."
      echo "  --log-file <path>   HA log file path (default: /var/log/home-assistant.log)"
      echo "                      Can also be set via the HA_LOG_FILE environment variable."
      echo "  --db-url <url>      recorder DB URL (default: sqlite:////tmp/homeassistant.db)"
      echo "                      Can also be set via the HA_DB_URL environment variable."
      echo "                      Default is tmpfs (lost on reboot); point at a persistent path to keep history."
      echo "  --with-configurator Install HASS Configurator, a web-based file editor on port 3218 (default: disabled)"
      echo "                      Can also be enabled via the HA_INSTALL_CONFIGURATOR environment variable."
      echo "                      It has no authentication of its own; only enable it on a trusted network."
      echo "  --no-configurator   Do not install HASS Configurator, and remove one installed by an earlier run."
      echo ""
      echo "Exit codes:"
      echo "  0   success"
      echo "  $EXIT_USAGE  unknown option or missing option value"
      echo "  $EXIT_HA_RUNNING  Home Assistant (or HASS Configurator) is still running"
      echo "  $EXIT_NO_SPACE  not enough free disk space"
      echo "  $EXIT_NO_VERSION  no Home Assistant $HOMEASSISTANT_MAJOR_VERSION release found"
      echo "  $EXIT_UNSAFE_PATH  a path option is not an absolute path of safe characters"
      echo "  $EXIT_NO_TARGET  a non-default directory does not exist (external disk not mounted?)"
      echo "  $EXIT_PATCH  a patch of the Home Assistant source did not apply (installer does not match the HA release)"
      echo "  other  a command failed; see the output above"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit "$EXIT_USAGE"
      ;;
  esac
done

if pgrep -a -f "bin/hass"; then
  # Killing the process by hand does not work: procd restarts it (respawn).
  {
    echo "ERROR: Home Assistant or HASS Configurator is running. Stop it to free RAM for the installation:"
    [ -x /etc/init.d/homeassistant ] && echo "  /etc/init.d/homeassistant stop"
    [ -x /etc/init.d/hass-configurator ] && echo "  /etc/init.d/hass-configurator stop"
    echo "Then wait until 'pgrep -f bin/hass' prints nothing, and run this script again."
  } >&2
  exit "$EXIT_HA_RUNNING"
fi

# Options not given are taken from an earlier installation, so that a re-run without them
# updates that installation instead of installing a second one at the defaults.
EXISTING_CMD=""
if [ -f /etc/init.d/homeassistant ]; then
  EXISTING_CMD=$(sed -n 's/^[[:space:]]*procd_set_param command //p' /etc/init.d/homeassistant)
fi
# Prints the value that follows option $1 in the existing hass command line.
existing_arg()
{
  echo " $EXISTING_CMD " | sed -n "s/.* ${1:?option} \([^ ]*\) .*/\1/p"
}
# Only init scripts written by this installer run "<venv>/bin/hass" with an absolute path.
EXISTING_VENV=$(echo " $EXISTING_CMD " | sed -n 's|.* \(/[^ ]*\)/bin/hass .*|\1|p')
if [ -n "$EXISTING_VENV" ]; then
  if [ -z "$VENV" ]; then
    VENV="$EXISTING_VENV"
    echo "Using --venv-dir $VENV of the existing installation"
  fi
  if [ -z "$HA_CONFIG" ]; then
    HA_CONFIG=$(existing_arg --config)
    [ -z "$HA_CONFIG" ] || echo "Using --config-dir $HA_CONFIG of the existing installation"
  fi
  if [ -z "$HA_LOG_FILE" ]; then
    HA_LOG_FILE=$(existing_arg --log-file)
    [ -z "$HA_LOG_FILE" ] || echo "Using --log-file $HA_LOG_FILE of the existing installation"
  fi
fi
if [ -z "$HA_INSTALL_CONFIGURATOR" ] && [ -f /etc/init.d/hass-configurator ]; then
  HA_INSTALL_CONFIGURATOR=1
  echo "Keeping HASS Configurator of the existing installation (--no-configurator removes it)"
fi
[ "$HA_INSTALL_CONFIGURATOR" = 1 ] || HA_INSTALL_CONFIGURATOR=""
STORAGE_TMP="${STORAGE_TMP:-$DEFAULT_TMP}"
VENV="${VENV:-$DEFAULT_VENV}"
HA_CONFIG="${HA_CONFIG:-$DEFAULT_CONFIG}"
HA_LOG_FILE="${HA_LOG_FILE:-$DEFAULT_LOG_FILE}"

require_safe_path --tmp-dir "$STORAGE_TMP"
require_safe_path --venv-dir "$VENV"
require_safe_path --config-dir "$HA_CONFIG"
require_safe_path --log-file "$HA_LOG_FILE"
require_existing_dir --tmp-dir "$STORAGE_TMP" "$DEFAULT_TMP"
require_existing_dir --venv-dir "$VENV" "$DEFAULT_VENV"
require_existing_dir --config-dir "$HA_CONFIG" "$DEFAULT_CONFIG"
require_existing_dir --log-file "$(dirname "$HA_LOG_FILE")" "$(dirname "$DEFAULT_LOG_FILE")"

# --tmp-dir names a parent directory that may hold other data (e.g. an external
# disk's mount point). Work only in our own child directory and delete only that;
# leftovers of earlier aborted runs carry the same name prefix.
TMP_BASE="$STORAGE_TMP"
mkdir -p "$TMP_BASE"
rm -rf "$TMP_BASE"/ha-install.*

# Free space needed (keep in sync with "Requirements" in README.md):
# - temp dir: downloads and build trees during the install (upper bound);
# - venv: measured ~300 MB for HA 2026.2 on x86_64, plus margin.
# A re-run replaces the old venv (uv venv --clear), so its size counts as free.
TMP_NEED_KB=524288
VENV_NEED_KB=358400
mkdir -p "$VENV"
VENV_OLD_KB=$(du -sk "$VENV" | awk '{print $1}')
if [ "$(mount_point_of "$TMP_BASE")" = "$(mount_point_of "$VENV")" ]; then
  check_free_space "$TMP_BASE" $((TMP_NEED_KB + VENV_NEED_KB)) "$VENV_OLD_KB"
else
  check_free_space "$TMP_BASE" "$TMP_NEED_KB"
  check_free_space "$VENV" "$VENV_NEED_KB" "$VENV_OLD_KB"
fi
STORAGE_TMP=$(mktemp -d "$TMP_BASE/ha-install.XXXXXX")
trap 'rm -rf "$STORAGE_TMP"' EXIT
export TMPDIR="$STORAGE_TMP"
export UV_LINK_MODE=copy

HOMEASSISTANT_VERSION=$(get_ha_version)

if [ "$HOMEASSISTANT_VERSION" = "" ]; then
  echo "ERROR: No Home Assistant $HOMEASSISTANT_MAJOR_VERSION release found on PyPI." >&2
  exit "$EXIT_NO_VERSION"
fi

echo "=========================================="
echo " Installing Home Assistant $HOMEASSISTANT_VERSION ..."
echo "=========================================="

(
wget -q "https://raw.githubusercontent.com/home-assistant/core/$HOMEASSISTANT_VERSION/homeassistant/package_constraints.txt" -O -
wget -q "https://raw.githubusercontent.com/home-assistant/core/$HOMEASSISTANT_VERSION/requirements.txt" -O -
wget -q "https://raw.githubusercontent.com/home-assistant/core/$HOMEASSISTANT_VERSION/requirements_all.txt" -O -
# fetch nabucasa deps from pyproject.toml (migrated from setup.py)
# awk range: start after "dependencies = [", stop at a line whose first
# non-whitespace character is "]" (handles both "  ]" and bare "]").
# Under pipefail every consumer must read its whole input: an early exit
# (awk exit, head, grep -q) kills the producer with SIGPIPE and fails the install.
wget -q "https://raw.githubusercontent.com/NabuCasa/hass-nabucasa/$(get_version hass-nabucasa)/pyproject.toml" -O - \
  | awk '/^dependencies = \[/ && !done {f=1;next} f && /^[[:space:]]*\]/{f=0;done=1;next} f' \
  | grep '[>=]=' \
  | sed -E 's/\s*"(.*)",?/\1/'
) > "$STORAGE_TMP/ha_requirements.txt"

HOMEASSISTANT_FRONTEND_VERSION=$(get_version home-assistant-frontend)
NABUCASA_VER=$(get_version hass-nabucasa)
ZIGPY_ZBOSS_VER=1.2.0

echo "Install base requirements from feed..."
apk update

apk add \
  python3-base \
  python3-pynacl

PYTHON_VERSION=$(get_python_version)
echo "Detected Python $PYTHON_VERSION"
SITE_PACKAGES="/usr/lib/python$PYTHON_VERSION/site-packages"
LUMI_GATEWAY=$(is_lumi_gateway)
GTW360_GATEWAY=$(is_gtw360)
NEED_ZHA="$LUMI_GATEWAY$GTW360_GATEWAY"

apk add \
  patch \
  unzip \
  libjpeg-turbo \
  python3-async-timeout \
  python3-asyncio \
  python3-attrs \
  python3-bcrypt \
  python3-boto3 \
  python3-botocore \
  python3-certifi \
  python3-cffi \
  python3-chardet \
  python3-codecs \
  python3-cryptodome \
  python3-cryptodomex \
  python3-cryptography \
  python3-ctypes \
  python3-dateutil \
  python3-dbm \
  python3-decimal \
  python3-defusedxml \
  python3-docutils \
  python3-email \
  python3-greenlet \
  python3-idna \
  python3-jinja2 \
  python3-jmespath \
  python3-light \
  python3-logging \
  python3-lru-dict \
  python3-lzma \
  python3-markupsafe \
  python3-multiprocessing \
  python3-ncurses \
  python3-netdisco \
  python3-openssl \
  python3-pillow \
  python3-pip \
  python3-pkg-resources \
  python3-ply \
  python3-psutil \
  python3-pycparser \
  python3-pydoc \
  python3-pyopenssl \
  python3-pytz \
  python3-requests \
  python3-s3transfer \
  python3-setuptools \
  python3-six \
  python3-slugify \
  python3-sqlalchemy \
  python3-sqlite3 \
  python3-uuid \
  python3-unittest \
  python3-urllib \
  python3-urllib3 \
  python3-xml \
  python3-yaml

apk add python3-pycares 2>/dev/null || true
if [ "$BROKEN_NUMPY" ]; then
  apk del python3-numpy 2>/dev/null || true
else
  apk add python3-numpy 2>/dev/null || true
fi
# Repair any apk packages that a previous failed install may have corrupted.
apk fix 2>/dev/null || true

cd "$STORAGE_TMP"

rm -rf "$HA_CONFIG/deps/"
find "$SITE_PACKAGES" -type d -name __pycache__ -print0 | xargs -0 rm -rf
rm -rf "$SITE_PACKAGES/botocore/data"
if [ -d "$SITE_PACKAGES/numpy" ]; then
  find "$SITE_PACKAGES/numpy" -iname tests -print0 | xargs -0 rm -rf
fi

echo "Create Python venv at $VENV (inheriting apk packages)..."
# uv is pinned because its handling of an existing venv changed between versions.
# --clear: a re-run (upgrade) always builds a clean venv; the config dir is not touched.
pip3 install --no-cache-dir "uv==0.13.7"
uv venv --clear --system-site-packages --seed "$VENV"
VENV_SITE_PACKAGES="$VENV/lib/python$PYTHON_VERSION/site-packages"
VENV_PIP="$VENV/bin/pip"

echo "Install base requirements from PyPI..."
$VENV_PIP install --no-cache-dir wheel "packaging>=24.0" "audioop-lts"
# Packages absent from the OpenWrt 25.12 feed or behind the required version;
# installed before pip freeze so they appear in owrt_constraints.txt.
# - aiohttp/aiohttp-cors/ciso8601: not in the 25.12 feed
# - attrs 25.4.0: feed ships 23.1.0, too old for HA 2026.2
# - aiodns 4.0.0: not in feed; triggers pip upgrade of pycares 4.10.0 → 5.0.1
#   (aiodns 4.0.0 requires pycares>=5.0.0; musl wheels available for both archs)
# - uv: installed system-wide by `pip3 install uv` above; inherited via --system-site-packages
$VENV_PIP install --no-cache-dir \
  "aiohttp==3.13.3" \
  "aiohttp-cors==0.8.1" \
  "ciso8601==2.3.3" \
  "attrs==25.4.0" \
  "aiodns==4.0.0"
$VENV_PIP freeze > "$STORAGE_TMP/freeze.txt"
grep -E 'aiohttp|async-timeout|crypto|YAML|ciso8601|pycares|cffi|pycparser' "$STORAGE_TMP/freeze.txt" \
  > "$STORAGE_TMP/owrt_constraints.txt"

cat << EOF > "$STORAGE_TMP/requirements_nodeps.txt"
$(version aioesphomeapi)
$(version esphome-dashboard-api)
$(version zeroconf)
$(version PyTurboJPEG)
EOF

$VENV_PIP install --no-cache-dir --no-deps -r "$STORAGE_TMP/requirements_nodeps.txt"
# Install aioesphomeapi's direct deps that --no-deps skipped
$VENV_PIP install --no-cache-dir \
  "async-interrupt>=1.2.0" \
  "chacha20poly1305-reuseable>=0.10.0" \
  "noiseprotocol>=0.3.1,<1.0" \
  "protobuf>=6,<8" \
  "tzlocal>=5.0,<6"
# add zeroconf
grep 'zeroconf' "$STORAGE_TMP/requirements_nodeps.txt" >> "$STORAGE_TMP/owrt_constraints.txt"
# fix deps — relax cryptography version pin (apk ships a different minor than aioesphomeapi expects)
sed -i \
  -e 's/cryptography\(.*\)/cryptography >=36.0.2/' \
  "$VENV_SITE_PACKAGES"/aioesphomeapi-*-info/METADATA

cat <<EOF > "$STORAGE_TMP/requirements.txt"
tzdata>=2021.2.post0  # 2021.6+ requirement
$(version aiozoneinfo)  # HA timezone util
$(version annotatedyaml)  # HA YAML util
$(version aiohasupervisor)  # HA supervisor client
$(version aiohttp-asyncmdnsresolver)  # HA mDNS resolver
$(version cronsim)  # HA automation scheduler
$(version voluptuous-openapi)  # HA config validation
$(version home-assistant-bluetooth)  # HA Bluetooth base types (used in core helpers)

$(version atomicwrites-homeassistant)  # nabucasa dep
$(version snitun)  # nabucasa dep
$(version astral)
$(version awesomeversion)
$(version PyJWT)
$(version voluptuous)
$(version voluptuous-serialize)
# $(version sqlalchemy)  # recorder requirement
$(version ulid-transform)  # utils
packaging>=24.0  # wheel 0.47.0 requires >=24.0; HA's pin of 23.1 conflicts
$(version psutil-home-assistant)
$(version async-interrupt)
$(version aiohttp-fast-zlib)  # pure-Python zlib speedup, required by http component

# homeassistant manifest requirements
$(version PyQRCode)
$(version pyMetno)
$(version mutagen)
$(version pyotp)
$(version gTTS)
$(version securetar)  # backup
$(version aiousbwatcher)  # usb
$(version python-miio)  # xiaomi_miio
$(version PyXiaomiGateway)
$(version aiodhcpwatcher)  # dhcp
$(version aiodiscover)  # dhcp
$(version httpx)  # image/http
$(version hassil)  # conversation
$(version home-assistant-intents)  # conversation
$(version paho-mqtt)  # mqtt
$(version pysnmp)  # snmp component (required by brother/__init__.py)
$(version webrtc-models)  # web_rtc component (required by camera/__init__.py)

# fixed dependencies
fnv-hash-fast==1.6.0  # cp313 musllinux wheels available; pure-Python workaround eliminated
# aiodns installed in early pip block (aiodns==4.0.0); pycares upgraded to 5.0.1 by pip
radios==0.3.2  # radio_browser
async-upnp-client==0.46.2  # updated for aiohttp 3.13.3; old freeze was for aiohttp<3.9
EOF

if [ "$NEED_ZHA" ]; then
  cat <<EOF >> "$STORAGE_TMP/requirements.txt"
# zha requirements (zha package pulls in zigpy, bellows, zigpy-zigate, and other backends)
$(version zha)
$(version serialx)
EOF
fi

if [ "$HA_INSTALL_CONFIGURATOR" ]; then
  cat <<EOF >> "$STORAGE_TMP/requirements.txt"
# extra services
hass-configurator==0.6.0
EOF
fi


# netifaces: C extension, no musl wheel. Install netifaces2 (has musl wheels) and create a
# compatibility shim so pip treats netifaces as already installed when building python-miio deps.
$VENV_PIP install --no-cache-dir netifaces2
SITE="$VENV_SITE_PACKAGES"
printf 'from netifaces2 import *\n' > "$SITE/netifaces.py"
DIST="$SITE/netifaces-0.11.0.dist-info"
mkdir -p "$DIST"
printf 'Metadata-Version: 2.1\nName: netifaces\nVersion: 0.11.0\n' > "$DIST/METADATA"
printf 'Wheel-Version: 1.0\nGenerator: shim\nRoot-Is-Purelib: true\nTag: py3-none-any\n' > "$DIST/WHEEL"
printf 'netifaces.py,,\nnetifaces-0.11.0.dist-info/METADATA,,\nnetifaces-0.11.0.dist-info/WHEEL,,\nnetifaces-0.11.0.dist-info/INSTALLER,,\nnetifaces-0.11.0.dist-info/RECORD,,\n' > "$DIST/RECORD"
printf 'pip\n' > "$DIST/INSTALLER"

# pip3 install --no-cache-dir -c "$STORAGE_TMP/owrt_constraints.txt" -r "$STORAGE_TMP/requirements.txt"
# install one-by-one to avoid memory issues
sed -E 's/\[.*\]//g' "$STORAGE_TMP/requirements.txt" >> "$STORAGE_TMP/owrt_constraints.txt"
while IFS= read -r p; do
  pkg_with_ver=$(echo "$p" | awk '{gsub(/ *#.*/,"");}1')
  if [ "$pkg_with_ver" ]; then
    $VENV_PIP install --no-cache-dir -c "$STORAGE_TMP/owrt_constraints.txt" "$pkg_with_ver"
  fi
done < "$STORAGE_TMP/requirements.txt"

if [ "$GTW360_GATEWAY" ]; then
  $VENV_PIP install --no-deps "zigpy-zboss==$ZIGPY_ZBOSS_VER"
  sed -i -E 's/Requires-.*(jsonschema|coloredlogs)//g' "$VENV_SITE_PACKAGES"/zigpy_zboss-*-info/METADATA
fi

if [ "$NEED_ZHA" ]; then
  # show internal serial ports for Xiaomi Gateway
  sed -i 's/ttyXRUSB\*/ttymxc[1-9]/' "$VENV_SITE_PACKAGES/serial/tools/list_ports_linux.py"
  sed -i 's/if info.subsystem != "platform"]/]/' "$VENV_SITE_PACKAGES/serial/tools/list_ports_linux.py"
fi

# fix deps — relax version pins; handles both dist-info and egg-info layouts
for f in "$SITE_PACKAGES"/botocore-*-info/METADATA; do
  [ -f "$f" ] && sed -i 's/urllib3 \(.*\)/urllib3 (>=1.20)/' "$f"
done
for f in "$SITE_PACKAGES"/boto3-*-info/METADATA; do
  [ -f "$f" ] && sed -i 's/botocore \(.*\)/botocore (>=1.12.0)/' "$f"
done
for f in "$SITE_PACKAGES"/botocore-*.egg-info/requires.txt; do
  [ -f "$f" ] && sed -i 's/urllib3<1.25,>=1.20/urllib3>=1.20/' "$f"
done
for f in "$SITE_PACKAGES"/boto3-*.egg-info/requires.txt; do
  [ -f "$f" ] && sed -i 's/botocore<1.13.0,>=1.12.135/botocore<1.13.0,>=1.12.0/' "$f"
done
rm -rf "$VENV_SITE_PACKAGES/pycountry/locales" \
       "$VENV_SITE_PACKAGES/pycountry/tests"

echo "Install hass_nabucasa and ha-frontend..."
# PyPI sdist, not the github.com archive: OpenWrt 25.12's wget (uclient-fetch) times out on github.com.
wget "https://files.pythonhosted.org/packages/source/h/hass_nabucasa/hass_nabucasa-$NABUCASA_VER.tar.gz" -O "hass_nabucasa-$NABUCASA_VER.tar.gz"
tar -zxf "hass_nabucasa-$NABUCASA_VER.tar.gz"
cd "hass_nabucasa-$NABUCASA_VER"
# strip version pins from whichever build file nabucasa uses
[ -f setup.py ] && sed -i 's/[<=>]=.*"/"/' setup.py
[ -f pyproject.toml ] && sed -i 's/[<=>]=.*"/"/' pyproject.toml
rm -rf "$VENV_SITE_PACKAGES"/hass_nabucasa-*.egg
$VENV_PIP install . --no-cache-dir -c "$STORAGE_TMP/owrt_constraints.txt"
cd ..
rm -rf "hass_nabucasa-$NABUCASA_VER.tar.gz" "hass_nabucasa-$NABUCASA_VER"

# cleanup
find "$VENV_SITE_PACKAGES" -iname tests -print0 | xargs -0 rm -rf

# frontend zip is large; download directly to STORAGE_TMP
cd "$STORAGE_TMP"
rm -rf "home-assistant-frontend.zip" "home-assistant-frontend-$HOMEASSISTANT_FRONTEND_VERSION"
rm -rf "$VENV_SITE_PACKAGES/hass_frontend"
rm -rf "$VENV_SITE_PACKAGES"/home_assistant_frontend-*
wget https://pypi.org/simple/home-assistant-frontend/ -O - \
  | grep "home_assistant_frontend-$HOMEASSISTANT_FRONTEND_VERSION-py3" \
  | cut -d '"' -f2 \
  | xargs wget -O "$STORAGE_TMP/home-assistant-frontend.zip"
unzip -qqo "$STORAGE_TMP/home-assistant-frontend.zip" -d home-assistant-frontend
rm -f "$STORAGE_TMP/home-assistant-frontend.zip"
cd home-assistant-frontend
find ./hass_frontend/frontend_es5 -name '*.js' -exec rm -rf {} \;
find ./hass_frontend/frontend_es5 -name '*.map' -exec rm -rf {} \;
find ./hass_frontend/frontend_es5 -name '*.txt' -exec rm -rf {} \;
find ./hass_frontend/frontend_latest -name '*.js' -exec rm -rf {} \;
find ./hass_frontend/frontend_latest -name '*.map' -exec rm -rf {} \;
find ./hass_frontend/frontend_latest -name '*.txt' -exec rm -rf {} \;

find ./hass_frontend/static/mdi -name '*.json' -maxdepth 1 -exec rm -rf {} \;
find ./hass_frontend/static/polyfills -name '*.js' -maxdepth 1 -exec rm -rf {} \;
find ./hass_frontend/static/polyfills -name '*.map' -maxdepth 1 -exec rm -rf {} \;
find ./hass_frontend/static/locale-data -name '*.json' -exec rm -rf {} \;

# gzip translations in place; the server serves .json.gz with Content-Encoding: gzip
find ./hass_frontend/static/translations -name '*.json' -exec gzip -f {} \;

mv hass_frontend "$VENV_SITE_PACKAGES"
mv "home_assistant_frontend-$HOMEASSISTANT_FRONTEND_VERSION.dist-info" "$VENV_SITE_PACKAGES"
cd ..
rm -rf home-assistant-frontend

echo "Install HASS"
$VENV_PIP install --no-cache-dir --upgrade typing-extensions || true

cd "$STORAGE_TMP"
rm -rf homeassistant.tar.gz "homeassistant-$HOMEASSISTANT_VERSION" .cache pip-*
wget "https://pypi.python.org/packages/source/h/homeassistant/homeassistant-$HOMEASSISTANT_VERSION.tar.gz" -O homeassistant.tar.gz

cat <<EOF > "$STORAGE_TMP/ha_components.txt"
__init__.py
ai_task
air_quality
alarm_control_panel
alert
alexa
analytics
api
application_credentials
assist_pipeline
assist_satellite
auth
automation
backup
binary_sensor
blueprint
brother
button
calendar
camera
climate
cloud
command_line
config
conversation
counter
cover
date
datetime
default_config
device_automation
device_tracker
dhcp
diagnostics
energy
esphome
event
fan
file
file_upload
frontend
geo_location
google_assistant
google_translate
group
hassio
hardware
history
homeassistant
homeassistant_alerts
http
humidifier
image
image_processing
image_upload
input_boolean
input_button
input_datetime
input_number
input_select
input_text
integration
intent
labs
lawn_mower
light
local_todo
lock
logbook
logger
lovelace
mailbox
manual
map
media_player
media_source
met
min_max
mobile_app
mpd
mqtt
my
network
notify
number
onboarding
panel_custom
panel_iframe
persistent_notification
person
proximity
python_script
radio_browser
recorder
remote
repairs
rest
safe_mode
scene
schedule
script
search
select
sensor
shopping_list
siren
snmp
ssdp
stream
stt
sun
switch
switch_as_x
system_health
system_log
tag
telegram
telegram_bot
template
text
time
time_date
timer
todo
trace
tts
update
upnp
usb
vacuum
valve
wake_on_lan
wake_word
water_heater
weather
web_rtc
webhook
websocket_api
workday
xiaomi_aqara
xiaomi_miio
yeelight
zeroconf
zone
EOF
if [ "$NEED_ZHA" ]; then
  echo "zha" >> "$STORAGE_TMP/ha_components.txt"
fi

# create fake structure to get full list of components
TMPSTRUCT="$STORAGE_TMP/t"
rm -rf "$TMPSTRUCT"
tar -ztf homeassistant.tar.gz | grep '/homeassistant/components/' | sed 's/^/t\//' | xargs mkdir -p
rx=$(sed -e 's/^/^/' -e 's/$/$/' "$STORAGE_TMP/ha_components.txt" | head -c -1 | tr '\n' '|')
for d in "$TMPSTRUCT"/homeassistant-*/homeassistant/components/*/; do
  comp=$(basename "$d")
  echo "$comp" | grep -E "$rx" >/dev/null || echo "*\/homeassistant\/components\/$comp"
done > "$STORAGE_TMP/ha_exclude.txt"
rm -rf "$TMPSTRUCT" "$STORAGE_TMP/ha_components.txt"

# extract without components to reduce space
tar -zxf homeassistant.tar.gz -X "$STORAGE_TMP/ha_exclude.txt"
rm -rf "$STORAGE_TMP/ha_exclude.txt"

rm -rf homeassistant.tar.gz
cd "homeassistant-$HOMEASSISTANT_VERSION/homeassistant/"
echo '' > requirements.txt
sed -i "s/[>=]=.*//g" package_constraints.txt

cd components

# relax dependencies
spatch recorder/manifest.json 's/sqlalchemy==[0-9\.]*/sqlalchemy/i'
spatch image_upload/manifest.json 's/pillow==[0-9\.]*/pillow/i'
spatch image_upload/__init__.py 's/, UnidentifiedImageError//'
spatch image_upload/__init__.py 's/except UnidentifiedImageError/except OSError/'
spatch zeroconf/manifest.json 's/zeroconf==[0-9\.]*/zeroconf/i'
#sed -i 's/netdisco==[0-9\.]*/netdisco/' discovery/manifest.json
spatch mobile_app/manifest.json 's/PyNaCl==[0-9\.]*/PyNaCl/i'
spatch radio_browser/manifest.json 's/radios==[0-9\.]*/radios/i'
# Remove C-extension audio packages that have no musl wheels.
# Use Python to edit manifest.json so the result is always valid JSON
# (sed element-removal leaves orphan commas that break the parser).
python3 -c "
import json, re
f = 'assist_pipeline/manifest.json'
with open(f) as fp: m = json.load(fp)
drop = {'webrtc-noise-gain', 'pymicro-vad', 'pyspeex-noise'}
m['requirements'] = [r for r in m.get('requirements', [])
                     if re.split(r'[>=<!]', r)[0].strip().lower() not in drop]
with open(f, 'w') as fp: json.dump(m, fp, indent=2)
"
# pymicro_vad and pyspeex_noise have no musl wheels; stub hard imports so the module loads
spatch assist_pipeline/audio_enhancer.py 's/from pymicro_vad import MicroVad/MicroVad = None  # pymicro_vad unavailable on musl/'
spatch assist_pipeline/audio_enhancer.py 's/from pyspeex_noise import AudioProcessor/AudioProcessor = None  # pyspeex_noise unavailable on musl/'

# relax async-upnp-client versions
spatch yeelight/manifest.json 's/async-upnp-client==[0-9\.]*/async-upnp-client/i'
spatch upnp/manifest.json 's/async-upnp-client==[0-9\.]*/async-upnp-client/i'
spatch ssdp/manifest.json 's/async-upnp-client==[0-9\.]*/async-upnp-client/i'

# remove bluetooth support from esphome
mlpatch esphome/manifest.json \
  -E -e 's/, "bluetooth"//g' \
     -e 's/(, )?"bleak[-_]esphome"//' \
     -e 's/,\x01    "bleak-esphome==[0-9.]*"//g'
spatch esphome/diagnostics.py \
  's/from homeassistant.components.bluetooth/#from homeassistant.components.bluetooth/' \
  's/async_scanner_by_source//'
spatch esphome/__init__.py 's/from homeassistant.components.bluetooth import async_remove_scanner/async_remove_scanner = lambda hass, mac: None/'
spatch esphome/entry_data.py 's/from.*ESPHomeBluetoothDevice.*/ESPHomeBluetoothDevice = None/'
spatch -E esphome/manager.py 's/from.*async_connect_scanner.*/async def async_connect_scanner(*args, **kwargs): pass/'

# drop ffmpeg requirement from tts
spatch tts/manifest.json 's/, "ffmpeg"//'
spatch tts/__init__.py 's/ ffmpeg,//'

# drop matter requirement from google_assistant, it is a dependency for mobile_app
spatch -E google_assistant/manifest.json 's/(\, *)?"matter"//'

# drop av and numpy deps from stream (renamed from ha-av to av in 2026.2)
spatch stream/manifest.json \
  's/"av==[0-9\.]*", //' \
  's/, "numpy==[0-9\.]*"//'

# soft float, like mips32 don't have numpy. Cut it off
if ! [ -d "$SITE_PACKAGES/numpy" ]; then
  spatch stream/core.py \
    's/import numpy as np/np = None/' \
    's/np\.ndarray/Any/g' \
    's/TRANSFORM_IMAGE_FUNCTION[orientation]//'
fi
#sed -i -e 's/import av/#/' -e 's/av.logging/#/' stream/__init__.py
spatch stream/__init__.py 's/import av/av = None/'
spatch stream/worker.py 's/import av/av = None/'
spatch stream/recorder.py 's/import av/av = None/'

# fnv-hash-fast: cp313 musllinux wheels available on PyPI since 1.6.0; no workaround needed

if [ "$NEED_ZHA" ]; then
  # relax version pins — all Zigbee backends now bundled as deps of the zha PyPI package
  spatch zha/manifest.json 's/"zha==[0-9\.]*"/"zha"/i'
  spatch zha/manifest.json 's/"serialx==[0-9\.]*"/"serialx"/i'

  # Multi-line stubs use replace_text, not mlpatch: busybox sed writes "\x01" in a
  # replacement as a literal "x01", which produced invalid Python here.

  # stub homeassistant_hardware helpers in __init__.py (not installed on OpenWrt)
  replace_text zha/__init__.py \
'from homeassistant.components.homeassistant_hardware.helpers import (
    async_is_firmware_update_in_progress,
    async_notify_firmware_info,
    async_register_firmware_info_provider,
)' \
'async_is_firmware_update_in_progress = lambda *a, **kw: False
async_notify_firmware_info = lambda *a, **kw: None
async_register_firmware_info_provider = lambda *a, **kw: None'

  # stub ZigbeeFlowStrategy (from homeassistant_hardware, not installed on OpenWrt)
  # needed in both config_flow.py and radio_manager.py
  for f in zha/config_flow.py zha/radio_manager.py; do
    replace_text "$f" \
'from homeassistant.components.homeassistant_hardware.firmware_config_flow import (
    ZigbeeFlowStrategy,
)' \
'class ZigbeeFlowStrategy(str):
    RECOMMENDED = "recommended"
    ADVANCED = "advanced"'
  done
  spatch zha/config_flow.py \
    's/from homeassistant.components.homeassistant_hardware import silabs_multiprotocol_addon/silabs_multiprotocol_addon = None  #/' \
    's/from homeassistant.components.homeassistant_yellow import hardware as yellow_hardware/yellow_hardware = None  #/'

  # stub local zha/homeassistant_hardware.py (imports from global homeassistant_hardware)
  # cp zha/homeassistant_hardware.py zha/__homeassistant_hardware.py
  cat <<EOF > zha/homeassistant_hardware.py
def get_firmware_info(hass, config_entry): return None
EOF

  # cp zha/repairs/wrong_silabs_firmware.py zha/repairs/__wrong_silabs_firmware.py
  cat <<EOF > zha/repairs/wrong_silabs_firmware.py
ISSUE_WRONG_SILABS_FIRMWARE_INSTALLED = "wrong_silabs_firmware_installed"
async def warn_on_wrong_silabs_firmware(hass, device_path): return False
class AlreadyRunningEZSP(Exception): pass
EOF
fi

# Lumi Gateway (zigate): zigpy-zigate is now a direct dep of zha==0.0.90 — no manifest patch needed
# GTW360 Gateway (zboss): zigpy-zboss is NOT in zha deps; zboss pip install is handled above

# Trim default_config with JSON: removing '"x",' with sed misses the last list element.
# Prints each dependency to drop that the manifest does not have (any more).
DEFAULT_CONFIG_MISSING=$(python3 -c "
import json, sys
f = 'default_config/manifest.json'
drop = sys.argv[1:]
with open(f) as fp: m = json.load(fp)
deps = m.get('dependencies', [])
print('\\n'.join(d for d in drop if d not in deps))
m['dependencies'] = [d for d in deps if d not in drop]
with open(f, 'w') as fp: json.dump(m, fp, indent=2)
" cloud dhcp mobile_app usb bluetooth assist_pipeline stream)
for dep in $DEFAULT_CONFIG_MISSING; do
  patch_failed default_config/manifest.json "remove dependency $dep"
done
spatch frontend/manifest.json 's/==[0-9\.]*//g'

cd ../..
# integrations and helper sections leave as is, only nested items
spatch homeassistant/generated/config_flows.py 's/        "/        # "/'
spatch homeassistant/generated/config_flows.py 's/    # "mqtt"/    "mqtt"/'
spatch homeassistant/generated/config_flows.py 's/    # "esphome"/    "esphome"/'
spatch homeassistant/generated/config_flows.py 's/    # "met"/    "met"/'
spatch homeassistant/generated/config_flows.py 's/    # "radio_browser"/    "radio_browser"/'
if [ "$NEED_ZHA" ]; then
  spatch homeassistant/generated/config_flows.py 's/    # "zha"/    "zha"/'
fi

# disabling all zeroconf services
spatch homeassistant/generated/zeroconf.py 's/^    "_/    "_disabled_/'
# re-enable required ones
spatch homeassistant/generated/zeroconf.py 's/_disabled_esphomelib./_esphomelib./'
spatch homeassistant/generated/zeroconf.py 's/_disabled_miio./_miio./'

# disabling all supported_brands
if [ -f homeassistant/generated/supported_brands.py ]; then  # 2022.8
  spatch homeassistant/generated/supported_brands.py 's/^    /    # /'
else
  mkdir -p homeassistant/brands-disabled/
  mv homeassistant/brands/* homeassistant/brands-disabled/
fi

# backport orjson to classic json
# helpers/json.py
spatch homeassistant/helpers/json.py \
  's/orjson/json/' \
  's/\.decode(.*)//' \
  's/option=.*,/\n/' \
  's/.as_posix/.as_posix()\n    if isinstance(obj, (datetime.date, datetime.time)):\n        return obj.isoformat/' \
  's/json_bytes /json_bytes_old /' \
  's/return json_bytes(data)/return _json_default_encoder(data)/' \
  's/json_fragment = .*/json_fragment = json.loads/' \
  's/mode = "wb"/mode = "w"/'
echo 'def json_bytes(data): return json.dumps(data, default=json_encoder_default).encode("utf-8")' \
  >> homeassistant/helpers/json.py
# util/json.py
spatch homeassistant/util/json.py 's/orjson/json/'
# helpers/template/__init__.py (was helpers/template.py before 2026.2)
# aiohttp_client.py no longer uses orjson in 2026.2 — patch removed
spatch -E homeassistant/helpers/template/__init__.py \
  's/orjson/json/g' \
  's/\.decode(.*)//' \
  's/option=option/#option=option/' \
  's/json.OPT_[A-Z_0-9]*/0/g'
# aiohttp_zlib_ng: replaced by aiohttp_fast_zlib (pure Python) in 2026.2 — patches removed
# handler_cancellation: supported in aiohttp >= 3.9; we use 3.13.3 — patch removed

# Patch installation type
spatch homeassistant/helpers/system_info.py 's/"installation_type": "Unknown"/"installation_type": "Home Assistant on OpenWrt"/'
find . -type f -exec touch {} +

rm -rf "$VENV_SITE_PACKAGES"/homeassistant*

if [ ! -f setup.py ]; then
  awk \
    -v RS='dependencies[^\]]*?\n\]' \
    -v ORS= '1;NR==1{printf "dependencies = []"}' \
    pyproject.toml \
    > pyproject-new.toml \
    && mv pyproject-new.toml pyproject.toml
  sed -i -E -e 's/(setuptools)[~=]{1,2}[\.0-9]*/\1/' -e 's/(wheel)[~=]{1,2}[\.0-9]*/\1/' pyproject.toml
else
  sed -i 's/install_requires=REQUIRES/install_requires=[]/' setup.py
fi
HA_BUILD="$STORAGE_TMP/ha-build"
mkdir -p "$HA_BUILD"
ln -s "$HA_BUILD" ./build
$VENV_PIP install . --no-cache-dir -c "$STORAGE_TMP/owrt_constraints.txt"
cd ../
rm -rf "homeassistant-$HOMEASSISTANT_VERSION/" "$HA_BUILD" "$STORAGE_TMP"

IP=$(ip a | grep "inet .*br-lan" | cut -d " " -f6 | tail -1 | cut -d / -f1 || true)
if [ -z "$IP" ]; then
  IP=$(ip a | grep "inet " | cut -d " " -f6 | tail -1 | cut -d / -f1 || true)
fi

if [ ! -f "$HA_CONFIG/configuration.yaml" ]; then
  mkdir -p "$HA_CONFIG"
  ln -sf "$HA_CONFIG" /root/.homeassistant
  cat <<EOF > "$HA_CONFIG/configuration.yaml"
# Configure a default setup of Home Assistant (frontend, api, etc)
default_config:

# Text to speech
tts:
  - platform: google_translate

recorder:
  purge_keep_days: 1
  db_url: '$HA_DB_URL'
  include:
    entity_globs:
      - sensor.*illuminance_*
      - sensor.*btn0_*
      - sensor.*temperature_*
      - sensor.*humidity_*
      - sensor.*presence_*
      - light.*

history:
  include:
    entity_globs:
      - sensor.*illuminance_*
      - sensor.*btn0_*
      - sensor.*temperature_*
      - sensor.*humidity_*
      - sensor.*presence_*
      - light.*

logger:
  default: warning
  logs: {}
EOF

  if [ "$HA_INSTALL_CONFIGURATOR" ]; then
    cat <<EOF >> "$HA_CONFIG/configuration.yaml"

panel_iframe:
  configurator:
    title: Configurator
    icon: mdi:square-edit-outline
    url: http://$IP:3218
EOF
  fi

  cat <<EOF >> "$HA_CONFIG/configuration.yaml"

group: !include groups.yaml
automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
EOF

  touch "$HA_CONFIG/groups.yaml"
  touch "$HA_CONFIG/automations.yaml"
  touch "$HA_CONFIG/scripts.yaml"
  touch "$HA_CONFIG/scenes.yaml"
else
  echo "NOTE: $HA_CONFIG/configuration.yaml exists and is left unchanged."
  echo "      --db-url and the Configurator panel only take effect in a new configuration;"
  echo "      edit configuration.yaml to change them."
fi

echo "Create starting script in init.d"
cat <<EOF > /etc/init.d/homeassistant
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service()
{
    # Guard: venv may live on an external disk that failed to mount.
    # Return 0 so the boot sequence continues without error.
    [ -x $VENV/bin/hass ] || { logger -t homeassistant "$VENV/bin/hass not found — external disk not mounted?"; return 0; }
    procd_open_instance
    # The wrapper makes HA the kernel's first choice when memory runs out, so that an OOM kill
    # hits HA (restarted by respawn) and not dnsmasq or hostapd. procd has no parameter for it.
    procd_set_param command /bin/sh -c 'echo $HA_OOM_SCORE_ADJ > /proc/self/oom_score_adj; exec "\$0" "\$@"' $VENV/bin/hass --config $HA_CONFIG --log-file $HA_LOG_FILE --log-rotate-days 3
    # Restart after crashes and OOM kills; the 30 s delay lets memory settle.
    # Give up after 5 runs shorter than 1 h to stop a crash loop.
    procd_set_param respawn 3600 30 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /etc/init.d/homeassistant
/etc/init.d/homeassistant enable

if [ "$HA_INSTALL_CONFIGURATOR" ]; then
  cat <<EOF > /etc/init.d/hass-configurator
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service()
{
    [ -x $VENV/bin/hass-configurator ] || { logger -t hass-configurator "$VENV/bin/hass-configurator not found — external disk not mounted?"; return 0; }
    procd_open_instance
    procd_set_param command $VENV/bin/hass-configurator -b $HA_CONFIG
    procd_set_param respawn 3600 30 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
  chmod +x /etc/init.d/hass-configurator
  /etc/init.d/hass-configurator enable
elif [ -f /etc/init.d/hass-configurator ]; then
  # An earlier run installed it; without the option it must not keep starting at boot.
  echo "Remove HASS Configurator init script from an earlier installation"
  /etc/init.d/hass-configurator disable || true
  rm -f /etc/init.d/hass-configurator
fi

echo "Done."
echo ""
echo "Home Assistant is installed but not yet running."
echo "To start now:    /etc/init.d/homeassistant start"
if [ "$HA_INSTALL_CONFIGURATOR" ]; then
  echo "                 /etc/init.d/hass-configurator start"
  echo "Or simply reboot — both services start automatically on boot."
else
  echo "Or simply reboot — it starts automatically on boot."
fi
echo ""
echo "Once running, open in your browser:"
echo "  Home Assistant:    http://$IP:8123"
if [ "$HA_INSTALL_CONFIGURATOR" ]; then
  echo "  HASS Configurator: http://$IP:3218"
fi
