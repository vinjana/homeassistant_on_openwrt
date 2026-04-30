# Homeassistant on OpenWrt

This repo provides tools to install the Home Assistant on a system with OpenWrt installed. 
It provides the reduced version of HA with only minimal list of components included.
Additionally, it keeps MQTT, ESPHome, and ZHA components as they are widely used with smart home solutions.

Only specific HomeAssistant/OpenWRT combinations are supported. Please refer to the branches which are named by the OpenWRT version, to see which HA version is supported with which OpenWRT version.

It is distributed with a shell script that downloads and installs everything that required for a clean start.

### Requirements:
- 256 MB storage space
- 256 MB RAM
- OpenWrt 25.12.3 or newer installed

## Generic installation
Then, download the installer and run it. For instance:

```sh
ha_version=25.12
wget https://raw.githubusercontent.com/openlumi/homeassistant_on_openwrt/$ha_version/ha_install.sh -O - | sh
```

After script prints `Done.` you have Home Assistant installed. 
Start the service or reboot the device to get it start automatically.
The web interface will be on 8123 port after all components load.

![Home Assistant](homeassistant.png)

The only components with flows included are MQTT and ZHA.
After adding a component in the interface or via the config
HA could install dependencies and fails on finding them after installation.
In this case restarting HA could work.

Other components are not tested and may require additional changed in 
requirement versions or Python libraries.

## Installing on external storage

Home Assistant requires roughly 250 MB of storage for its Python packages, plus a growing
SQLite database.
If your router's internal flash is too small, put both on an external disk using the
`--venv-dir` and `--config-dir` options.

The install script creates an isolated Python virtual environment (venv) for HA.
The venv inherits the system Python packages installed by `apk` (cryptography, pillow, etc.)
and installs all pip-only packages into its own directory.
This keeps HA isolated from the rest of the system Python and makes the install fully
relocatable: point `--venv-dir` at any path and the venv lands there.

If the external disk fails to mount at boot, the router keeps routing and HA simply does
not start — the init script detects the missing venv and exits cleanly.
Recovering is a matter of attaching a new disk and re-running the install script.

### Prerequisites

Install USB storage support (once, requires a working internet connection):

```sh
apk update
apk add block-mount kmod-usb-storage kmod-fs-ext4 e2fsprogs
```

### Set up the external disk

Format the disk (skip if already formatted):

```sh
mkfs.ext4 /dev/sda1
```

Create the mount point and mount the disk:

```sh
mkdir -p /mnt/external
mount /dev/sda1 /mnt/external
```

Make the mount persistent by adding it to `/etc/fstab`:

```
/dev/sda1   /mnt/external   ext4   defaults,nofail   0 0
```

The `nofail` option ensures the router still boots cleanly if the disk is absent.

### Install HA onto the external disk

Pass `--venv-dir` and `--config-dir` to the install script:

```sh
ha_version=25.12
wget https://raw.githubusercontent.com/openlumi/homeassistant_on_openwrt/$ha_version/ha_install.sh -O ha_install.sh
chmod +x ha_install.sh
sh ha_install.sh \
  --venv-dir /mnt/external/homeassistant \
  --config-dir /mnt/external/ha-config
```

| Option | Default | What moves to the external disk |
|---|---|---|
| `--venv-dir` | `/opt/homeassistant` | Python venv (~250 MB of packages) |
| `--config-dir` | `/etc/homeassistant` | Config files and the SQLite database |

Both options can also be set via environment variables (`HA_VENV_DIR`, `HA_CONFIG_DIR`).
Run `sh ha_install.sh --help` to see all options.

### Temporary build directory

During installation `ha_install.sh` uses a temporary directory (`/root/tmp-ha` by default) for
downloading and unpacking packages. On devices with limited internal flash, this can fill the
primary disk. Point it at the external mount instead:

```sh
sh ha_install.sh \
  --tmp-dir   /mnt/external/ha-tmp \
  --venv-dir  /mnt/external/homeassistant \
  --config-dir /mnt/external/ha-config
```

The flag takes precedence over the environment variable (`HA_TMP_DIR`); the environment
variable takes precedence over the default.


## Feature support

### Core platform

All standard HA platform features are available:
automations, scripts, scenes, schedules, blueprints, templates, groups, helpers
(input booleans, numbers, selects, text, counters, timers, date/time),
todo lists, shopping list, person tracking, zones, tags, alerts, webhooks,
Python scripts, dashboard (Lovelace), history, logbook, energy dashboard, and backup.

The recorder uses SQLite. The default configuration stores the database in `/tmp` (RAM, cleared on reboot).
Set `db_url` in the `recorder:` block to a persistent path if you need history to survive reboots.

### Integrations

| Integration | Status | Notes |
|---|---|---|
| MQTT | ✓ | |
| ESPHome | ✓ | LAN-based; Bluetooth pairing not available |
| ZHA (Zigbee) | ✓ on Lumi/GTW360 only | Lumi Gateway uses zigpy-zigate; GTW360 uses zigpy-zboss; not available on other hardware |
| Xiaomi (xiaomi_miio, xiaomi_aqara) | ✓ | |
| Yeelight | ✓ | |
| Met.no weather | ✓ | |
| Google Translate TTS | ✓ | Audio delivery requires a media player entity |
| Telegram / Telegram Bot | ✓ | |
| REST & command_line | ✓ | |
| Template sensors/triggers | ✓ | |
| SNMP | ✓ | |
| Wake-on-LAN | ✓ | |
| MPD (music player) | ✓ | |
| Radio Browser | ✓ | |
| UPnP | ✓ | |
| Camera (still images) | ✓ | Live video streams not available (see below) |
| Brother printers | ✓ | |
| Conversation (text assistant) | ✓ | Text-based only; voice pipeline not available |
| Alexa (local API) | ✓ | |
| Google Assistant (local API) | ✓ | |

### Bundled extras

The install script also installs and enables the following tools, which are not part of HA core:

| Tool | Port | Notes |
|---|---|---|
| [hass-configurator](https://github.com/danielperna84/hass-configurator) | 3218 | Web-based config file editor; verified working |

### Not supported

| Feature | Reason |
|---|---|
| Bluetooth | No BLE stack on OpenWrt; all Bluetooth integrations are unavailable |
| Live video / camera streams | The `stream` component requires `ffmpeg`, which is not installed |
| Z-Wave | Component not included |
| Matter / Thread | Component not included |
| Nabu Casa cloud | Component installed but excluded from auto-load; enabling it is untested |
| Mobile App companion | Disabled |
| Voice pipeline (STT / wake word) | No suitable speech-to-text or wake-word hardware support on OpenWrt |
| Supervisor / add-ons | Requires HA OS or HA Supervised; not available on OpenWrt regardless of container runtime |

## ZHA usage on Xiaomi Gateway

The component uses internal UART to communicate with ZigBee chip.
The chip has to be flashed with a proper firmware to be able to 
communicate with the HA. The recommended firmware is v3.23:

https://github.com/openlumi/ZiGate/releases/download/55f8--20230114-1835/ZigbeeNodeControlBridge_JN5169_COORDINATOR_115200.bin 

You could try another Zigate firmwares for JN5169 chip. The baud rate
must be 115200 as it is hardcoded in zigpy-zigate.

Use **/dev/ttymxc1** port for ZHA configuration, it is connected to the zigbee chip.

It is REQUIRED to erase Persistent Data Manager (PDM) before adding new devices.
Otherwise, device adding fails.

Use luci zigbee tools submenu to send erase PDM command with the button or
erase PDM in console:

```sh
jntool erase_pdm
```

Zigbee port must not be locked with any program, like ZHA or zigbee2mqtt.

**NOTE: It may require restarting Home Assistant after adding a new 
component via the UI to let it see newly installed requirements. 
E.g. ZHA installs paho-mqtt and will not allow configuring it unless HA is 
restarted.**

## Enabling other components and installing custom

You may want to add more components to your HA installation.
In this case you have to download tar.gz from PyPI:
https://pypi.org/project/homeassistant/2024.3.3/#files
Then extract the content and copy the required components to 
`/usr/lib/python3.11/site-packages/homeassistant/components`
If the component uses the frontend wizard, you may want to uncomment the
corresponding line in 
`/usr/lib/python3.11/site-packages/homeassistant/generated/config_flows.py`
also.

Or you can create `custom_components` directory in `/etc/homeassistant` and
copy it there.

Try to install requirements from `manifest.json` with `pip3` manually
to check it installs and doesn't require pre-compiled C libraries.
Otherwise, you have to cross-compile python3 dependencies and install
them as `ipk` packages.

If the dependency is already installed via opkg or via pip3 you may want
to fix the strict dependency in `manifest.json` to a weaker one or remove 
versions at all.

## Code testing

The code has been tested with OpenWRT VMs on x86_64 and aarch64 architectures.
Reproducible tests are described in [tests/README.adoc](tests/README.adoc).
