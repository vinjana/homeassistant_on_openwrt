#!/bin/sh
# shellcheck shell=dash
# Homeassistant installer script by @devbis

get_ha_version()
{
  wget -q -O- https://pypi.org/simple/homeassistant/ | grep "$HOMEASSISTANT_MAJOR_VERSION" | tail -n 1 | sed -n 's/.*homeassistant-\([0-9.ab]*\)\..*/\1/p'
}

get_python_version()
{
  # apk list output: "python3-base-3.13.9-r3 x86_64 ..." — extract major.minor
  # sed targets the package name prefix directly to avoid matching other
  # version-like strings (e.g. license identifiers) elsewhere on the line.
  apk list python3-base 2>/dev/null | sed -n 's/^python3-base-\([0-9]*\.[0-9]*\)\.[0-9].*/\1/p' | head -1
}

get_version()
{
  local pkg="$1"
  grep -i -m 1 "${pkg}[<=>]=" "$STORAGE_TMP/ha_requirements.txt" | sed 's/.*[<=>]=\(.*\)/\1/g'
}

version()
{
  local pkg="$1"
  echo "$pkg==$(get_version "$pkg")"
}

is_lumi_gateway()
{
  grep -E '(dgnwg05lm|zhwg11lm)' /etc/board.json | tr -s '"' | cut -d\" -f4
}

is_gtw360()
{
  grep 'gtw360' /etc/board.json | tr -s '"' | cut -d\" -f4
}

int_version() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

mlpatch()
{
  # Multi-line sed in place: temporarily replaces newlines with \x01 (ASCII SOH;
  # never appears in Python source files) so that multi-line patterns can be
  # expressed as ordinary sed expressions.  Use \x01 in sed args wherever a
  # newline should be matched or produced.
  local f="$1"; shift
  tr '\n' '\x01' < "$f" | sed "$@" | tr '\x01' '\n' > "${f}.new" && mv "${f}.new" "$f"
}

check_free_space()
{
  local path="$1"
  local min_kb="$2"
  local free_kb
  mkdir -p "$path"
  free_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
  if [ "$free_kb" -lt "$min_kb" ]; then
    printf "ERROR: Not enough free space at %s: %d MB available, %d MB required.\n" \
      "$path" "$((free_kb / 1024))" "$((min_kb / 1024))" >&2
    exit 1
  fi
}

set -eu

HOMEASSISTANT_MAJOR_VERSION="2026.2"
export PIP_DEFAULT_TIMEOUT=100

# May be set externally to skip numpy on broken platforms (e.g. soft-float MIPS).
BROKEN_NUMPY="${BROKEN_NUMPY:-}"

# All temp files go here; exported as TMPDIR so pip and subprocesses use it too.
# Default is flash-backed /root/tmp-ha; override via HA_TMP_DIR or --tmp-dir.
STORAGE_TMP="${HA_TMP_DIR:-/root/tmp-ha}"

# Python venv for HA; override via HA_VENV_DIR or --venv-dir.
# Point at an external mount to keep HA packages off the internal flash.
VENV="${HA_VENV_DIR:-/opt/homeassistant}"

# HA config/data directory; override via HA_CONFIG_DIR or --config-dir.
# The SQLite database grows over time — point at an external mount to keep
# it off internal flash (e.g. /mnt/external/homeassistant).
HA_CONFIG="${HA_CONFIG_DIR:-/etc/homeassistant}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tmp-dir)
      STORAGE_TMP="$2"
      shift 2
      ;;
    --tmp-dir=*)
      STORAGE_TMP="${1#*=}"
      shift
      ;;
    --venv-dir)
      VENV="$2"
      shift 2
      ;;
    --venv-dir=*)
      VENV="${1#*=}"
      shift
      ;;
    --config-dir)
      HA_CONFIG="$2"
      shift 2
      ;;
    --config-dir=*)
      HA_CONFIG="${1#*=}"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--tmp-dir <path>] [--venv-dir <path>] [--config-dir <path>]"
      echo ""
      echo "Options:"
      echo "  --tmp-dir <path>    Temporary build directory (default: /root/tmp-ha)"
      echo "                      Can also be set via the HA_TMP_DIR environment variable."
      echo "                      Use a path on an external mount to avoid filling the primary disk."
      echo "  --venv-dir <path>   Python virtual environment directory (default: /opt/homeassistant)"
      echo "                      Can also be set via the HA_VENV_DIR environment variable."
      echo "                      Point at an external mount to keep HA packages off internal flash."
      echo "  --config-dir <path> HA configuration and data directory (default: /etc/homeassistant)"
      echo "                      Can also be set via the HA_CONFIG_DIR environment variable."
      echo "                      Point at an external mount so the SQLite DB does not fill internal flash."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if pgrep -a -f "bin/hass"; then
  echo "Stop running process of Home Assistant (and HASS Configurator) to free RAM for installation";
  exit 1;
fi

check_free_space "$STORAGE_TMP" 524288  # ~256 MB final + headroom for zip download
rm -rf "$STORAGE_TMP"
mkdir -p "$STORAGE_TMP"
export TMPDIR="$STORAGE_TMP"
export UV_LINK_MODE=copy

HOMEASSISTANT_VERSION=$(get_ha_version)

if [ "$HOMEASSISTANT_VERSION" = "" ]; then
  echo "Incorrect Home Assistant version. Exiting ...";
  exit 1;
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
wget -q "https://raw.githubusercontent.com/NabuCasa/hass-nabucasa/$(get_version hass-nabucasa)/pyproject.toml" -O - \
  | awk '/^dependencies = \[/{f=1;next} f && /^[[:space:]]*\]/{exit} f' \
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
find "$SITE_PACKAGES" | grep -E "/__pycache__$" | xargs rm -rf
rm -rf "$SITE_PACKAGES/botocore/data"
find "$SITE_PACKAGES/numpy" -iname tests -print0 | xargs -0 rm -rf

echo "Create Python venv at $VENV (inheriting apk packages)..."
pip3 install --no-cache-dir uv
uv venv --system-site-packages --seed "$VENV"
VENV_SITE_PACKAGES="$VENV/lib/python$PYTHON_VERSION/site-packages"
VENV_PIP="$VENV/bin/pip"

echo "Install base requirements from PyPI..."
$VENV_PIP install --no-cache-dir wheel "packaging>=24.0"
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

# extra services
hass-configurator==0.6.0
EOF

if [ "$NEED_ZHA" ]; then
  cat <<EOF >> "$STORAGE_TMP/requirements.txt"
# zha requirements (zha package pulls in zigpy, bellows, zigpy-zigate, and other backends)
$(version zha)
$(version serialx)
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
  sed -i -E 's/Requires-.*(jsonschema|coloredlogs)//g' $VENV_SITE_PACKAGES/zigpy_zboss-*-info/METADATA
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
rm -rf $VENV_SITE_PACKAGES/pycountry/locales \
       $VENV_SITE_PACKAGES/pycountry/tests

echo "Install hass_nabucasa and ha-frontend..."
wget "https://github.com/NabuCasa/hass-nabucasa/archive/$NABUCASA_VER.tar.gz" -O - > "hass-nabucasa-$NABUCASA_VER.tar.gz"
tar -zxf "hass-nabucasa-$NABUCASA_VER.tar.gz"
cd "hass-nabucasa-$NABUCASA_VER"
# strip version pins from whichever build file nabucasa uses
[ -f setup.py ] && sed -i 's/[<=>]=.*"/"/' setup.py
[ -f pyproject.toml ] && sed -i 's/[<=>]=.*"/"/' pyproject.toml
rm -rf "$VENV_SITE_PACKAGES"/hass_nabucasa-*.egg
$VENV_PIP install . --no-cache-dir -c "$STORAGE_TMP/owrt_constraints.txt"
cd ..
rm -rf "hass-nabucasa-$NABUCASA_VER.tar.gz" "hass-nabucasa-$NABUCASA_VER"

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
  echo "$comp" | grep -q -E "$rx" || echo "*\/homeassistant\/components\/$comp"
done > "$STORAGE_TMP/ha_exclude.txt"
rm -rf "$TMPSTRUCT" "$STORAGE_TMP/ha_components.txt"

# extract without components to reduce space
tar -zxf homeassistant.tar.gz -X "$STORAGE_TMP/ha_exclude.txt"
rm -rf "$STORAGE_TMP/ha_exclude.txt"

rm -rf homeassistant.tar.gz
cd "homeassistant-$HOMEASSISTANT_VERSION/homeassistant/"
echo '' > requirements.txt
sed -i "s/[>=]=.*//g" package_constraints.txt

# replace LRU with simple dict (helpers/template/ is a package in 2026.2)
sed -i -e 's/from lru import LRU/LRU = lambda x: dict()/' -e 's/lru.get_size()/128/' -e 's/lru.set_size/pass  # \0/' helpers/template/__init__.py

cd components

# replace LRU with simple dict
# recorder/core.py and recorder/db_schema.py no longer use lru-dict in 2026.2
# recorder manifest no longer lists lru-dict
sed -i 's/from lru import LRU/LRU = lambda x: dict()/' recorder/table_managers/event_types.py
sed -i -e 's/from lru import LRU/LRU = lambda x: dict()/' -e 's/lru.get_size()/128/' -e 's/lru.set_size/pass  # \0/' recorder/table_managers/__init__.py
sed -i -e 's/from lru import LRU/LRU = lambda x: dict()/' -e 's/lru.get_size()/128/' -e 's/lru.set_size/pass  # \0/' recorder/table_managers/statistics_meta.py
sed -i 's/from lru import LRU/LRU = lambda x: dict()/' http/static.py
# esphome/entry_data.py no longer uses lru-dict in 2026.2

# relax dependencies
sed -i 's/sqlalchemy==[0-9\.]*/sqlalchemy/i' recorder/manifest.json
sed -i 's/pillow==[0-9\.]*/pillow/i' image_upload/manifest.json
sed -i 's/, UnidentifiedImageError//' image_upload/__init__.py
sed -i 's/except UnidentifiedImageError/except OSError/' image_upload/__init__.py
sed -i 's/zeroconf==[0-9\.]*/zeroconf/i' zeroconf/manifest.json
#sed -i 's/netdisco==[0-9\.]*/netdisco/' discovery/manifest.json
sed -i 's/PyNaCl==[0-9\.]*/PyNaCl/i' mobile_app/manifest.json
sed -i 's/defusedxml==[0-9\.]*/defusedxml/i' ssdp/manifest.json
sed -i 's/netdisco==[0-9\.]*/netdisco/i' ssdp/manifest.json
sed -i 's/radios==[0-9\.]*/radios/i' radio_browser/manifest.json
sed -i 's/"webrtc-noise-gain==[0-9\.]*"//i' assist_pipeline/manifest.json
sed -i 's/"pymicro-vad==[0-9\.]*"//i' assist_pipeline/manifest.json
# pymicro_vad has no musl wheel; stub the hard import so the module loads
sed -i 's/from pymicro_vad import MicroVad/MicroVad = None  # pymicro_vad unavailable on musl/' assist_pipeline/audio_enhancer.py

# relax async-upnp-client versions
sed -i 's/async-upnp-client==[0-9\.]*/async-upnp-client/i' yeelight/manifest.json
sed -i 's/async-upnp-client==[0-9\.]*/async-upnp-client/i' upnp/manifest.json
sed -i 's/async-upnp-client==[0-9\.]*/async-upnp-client/i' ssdp/manifest.json

# remove bluetooth support from esphome
mlpatch esphome/manifest.json \
  -E -e 's/, "bluetooth"//g' \
     -e 's/(, )?"bleak[-_]esphome"//' \
     -e 's/,\x01    "bleak-esphome==[0-9.]*"//g'
sed -i -e 's/    config_entry.unique_id/    False/' -e 's/from homeassistant.components.bluetooth/#from homeassistant.components.bluetooth/' -e 's/async_scanner_by_source//' esphome/diagnostics.py
sed -i 's/from homeassistant.components.bluetooth import async_remove_scanner/async_remove_scanner = lambda hass, mac: None/' esphome/__init__.py
sed -i 's/from.*ESPHomeBluetoothDevice.*/ESPHomeBluetoothDevice = None/' esphome/entry_data.py
sed -i -E 's/from.*async_connect_scanner.*/async def async_connect_scanner(*args, **kwargs): pass/' esphome/manager.py

# drop ffmpeg requirement from tts
sed -i 's/, "ffmpeg"//' tts/manifest.json
sed -i 's/ ffmpeg,//' tts/__init__.py

# drop matter requirement from google_assistant, it is a dependency for mobile_app
sed -i -E 's/(\, *)?"matter"//' google_assistant/manifest.json

# drop av and numpy deps from stream (renamed from ha-av to av in 2026.2)
sed -i -e 's/"av==[0-9\.]*", //' -e 's/, "numpy==[0-9\.]*"//' stream/manifest.json

# soft float, like mips32 don't have numpy. Cut it off
if ! [ -d "$SITE_PACKAGES/numpy" ]; then
  sed -i \
    -e 's/import numpy as np/np = None/' \
    -e 's/np\.ndarray/Any/g' \
    -e 's/TRANSFORM_IMAGE_FUNCTION[orientation]//' \
    stream/core.py
fi
#sed -i -e 's/import av/#/' -e 's/av.logging/#/' stream/__init__.py
sed -i 's/import av/av = None/' stream/__init__.py
sed -i 's/import av/av = None/' stream/worker.py
sed -i 's/import av/av = None/' stream/recorder.py

# fnv-hash-fast: cp313 musllinux wheels available on PyPI since 1.6.0; no workaround needed

if [ "$NEED_ZHA" ]; then
  # relax version pins — all Zigbee backends now bundled as deps of the zha PyPI package
  sed -i 's/"zha==[0-9\.]*"/"zha"/i' zha/manifest.json
  sed -i 's/"serialx==[0-9\.]*"/"serialx"/i' zha/manifest.json

  # stub homeassistant_hardware helpers in __init__.py (not installed on OpenWrt)
  mlpatch zha/__init__.py \
    -E 's/from homeassistant\.components\.homeassistant_hardware\.helpers import \(\x01    async_is_firmware_update_in_progress,\x01    async_notify_firmware_info,\x01    async_register_firmware_info_provider,\x01\)/async_is_firmware_update_in_progress = lambda *a, **kw: False\x01async_notify_firmware_info = lambda *a, **kw: None\x01async_register_firmware_info_provider = lambda *a, **kw: None/'

  # stub ZigbeeFlowStrategy (from homeassistant_hardware, not installed on OpenWrt)
  # needed in both config_flow.py and radio_manager.py
  for f in zha/config_flow.py zha/radio_manager.py; do
    mlpatch "$f" \
      -E 's/from homeassistant\.components\.homeassistant_hardware\.firmware_config_flow import \(\x01    ZigbeeFlowStrategy,\x01\)/class ZigbeeFlowStrategy(str):\x01    RECOMMENDED = "recommended"\x01    ADVANCED = "advanced"/'
  done
  sed -i -e 's/from homeassistant.components.homeassistant_hardware import silabs_multiprotocol_addon/silabs_multiprotocol_addon = None  #/' -e 's/from homeassistant.components.homeassistant_yellow import hardware as yellow_hardware/yellow_hardware = None  #/' zha/config_flow.py

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

sed -i 's/"cloud",//' default_config/manifest.json
sed -i 's/"dhcp",//' default_config/manifest.json
sed -i 's/"mobile_app",//' default_config/manifest.json
sed -i 's/"updater",//' default_config/manifest.json
sed -i 's/"usb",//' default_config/manifest.json
sed -i 's/"bluetooth",//' default_config/manifest.json
sed -i 's/"assist_pipeline",//' default_config/manifest.json
sed -i 's/"stream",//' default_config/manifest.json
sed -i 's/==[0-9\.]*//g' frontend/manifest.json

cd ../..
# integrations and helper sections leave as is, only nested items
sed -i 's/        "/        # "/' homeassistant/generated/config_flows.py
sed -i 's/    # "mqtt"/    "mqtt"/' homeassistant/generated/config_flows.py
sed -i 's/    # "esphome"/    "esphome"/' homeassistant/generated/config_flows.py
sed -i 's/    # "met"/    "met"/' homeassistant/generated/config_flows.py
sed -i 's/    # "radio_browser"/    "radio_browser"/' homeassistant/generated/config_flows.py
if [ "$NEED_ZHA" ]; then
  sed -i 's/    # "zha"/    "zha"/' homeassistant/generated/config_flows.py
fi

# disabling all zeroconf services
sed -i 's/^    "_/    "_disabled_/' homeassistant/generated/zeroconf.py
# re-enable required ones
sed -i 's/_disabled_esphomelib./_esphomelib./' homeassistant/generated/zeroconf.py
sed -i 's/_disabled_miio./_miio./' homeassistant/generated/zeroconf.py

# disabling all supported_brands
if [ -f homeassistant/generated/supported_brands.py ]; then  # 2022.8
  sed -i 's/^    /    # /' homeassistant/generated/supported_brands.py
else
  mkdir -p homeassistant/brands-disabled/
  mv homeassistant/brands/* homeassistant/brands-disabled/
fi

# backport orjson to classic json
# helpers/json.py
sed -i \
  -e 's/orjson/json/' \
  -e 's/\.decode(.*)//' \
  -e 's/option=.*,/\n/' \
  -e 's/.as_posix/.as_posix()\n    if isinstance(obj, (datetime.date, datetime.time)):\n        return obj.isoformat/' \
  -e 's/json_bytes /json_bytes_old /' \
  -e 's/return json_bytes(data)/return _json_default_encoder(data)/' \
  -e 's/json_fragment = .*/json_fragment = json.loads/' \
  -e 's/mode = "wb"/mode = "w"/' \
  homeassistant/helpers/json.py
echo 'def json_bytes(data): return json.dumps(data, default=json_encoder_default).encode("utf-8")' \
  >> homeassistant/helpers/json.py
# util/json.py
sed -i -e 's/orjson/json/' -e 's/\.decode(.*)//' -e 's/option=.*/\n/' homeassistant/util/json.py
# helpers/template/__init__.py (was helpers/template.py before 2026.2)
# aiohttp_client.py no longer uses orjson in 2026.2 — patch removed
sed -i -E \
  -e 's/orjson/json/g' \
  -e 's/\.decode(.*)//' \
  -e 's/(b64(de|en)code.*?)/\1.decode("utf-8")/' \
  -e 's/option=option/#option=option/' \
  -e 's/json.OPT_[A-Z_0-9]*/0/g' \
  homeassistant/helpers/template/__init__.py
# aiohttp_zlib_ng: replaced by aiohttp_fast_zlib (pure Python) in 2026.2 — patches removed
# handler_cancellation: supported in aiohttp >= 3.9; we use 3.13.3 — patch removed

# Patch installation type
sed -i 's/"installation_type": "Unknown"/"installation_type": "Home Assistant on OpenWrt"/' homeassistant/helpers/system_info.py
find . -type f -exec touch {} +
# Relax version specifiers to ">=MAJOR" so pip can satisfy them with the
# packages already installed by apk: e.g. aiohttp>=3.9.0 → aiohttp>=3.
sed -i -E 's/(==|>=|~=)([0-9]+)\.[0-9][0-9.a-z]*/>=\2/g' setup.cfg

rm -rf $VENV_SITE_PACKAGES/homeassistant*

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

IP=$(ip a | grep "inet .*br-lan" | cut -d " " -f6 | tail -1 | cut -d / -f1)
if [ -z "$IP" ]; then
  IP=$(ip a | grep "inet " | cut -d " " -f6 | tail -1 | cut -d / -f1)
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
    language: ru

recorder:
  purge_keep_days: 1
  db_url: 'sqlite:////tmp/homeassistant.db'
  include:
    entity_globs:
      - sensor.*illuminance_*
      - sensor.*btn0_*
      - sensor.*temperature_*
      - sensor.*humidity_*
      - sensor.*presence_*
      - light.*

panel_iframe:
  configurator:
    title: Configurator
    icon: mdi:square-edit-outline
    url: http://$IP:3218

group: !include groups.yaml
automation: !include automations.yaml
script: !include scripts.yaml
scene: !include scenes.yaml
EOF

  touch "$HA_CONFIG/groups.yaml"
  touch "$HA_CONFIG/automations.yaml"
  touch "$HA_CONFIG/scripts.yaml"
  touch "$HA_CONFIG/scenes.yaml"
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
    procd_set_param command $VENV/bin/hass --config $HA_CONFIG --log-file /var/log/home-assistant.log --log-rotate-days 3
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /etc/init.d/homeassistant
/etc/init.d/homeassistant enable

cat <<EOF > /etc/init.d/hass-configurator
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

start_service()
{
    [ -x $VENV/bin/hass-configurator ] || { logger -t hass-configurator "$VENV/bin/hass-configurator not found — external disk not mounted?"; return 0; }
    procd_open_instance
    procd_set_param command $VENV/bin/hass-configurator -b $HA_CONFIG
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /etc/init.d/hass-configurator
/etc/init.d/hass-configurator enable

echo "Done."
echo ""
echo "Home Assistant is installed but not yet running."
echo "To start now:    /etc/init.d/homeassistant start"
echo "                 /etc/init.d/hass-configurator start"
echo "Or simply reboot — both services start automatically on boot."
echo ""
echo "Once running, open in your browser:"
echo "  Home Assistant:    http://$IP:8123"
echo "  HASS Configurator: http://$IP:3218"
