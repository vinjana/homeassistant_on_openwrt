# Homeassistant on OpenWrt

This repo provides tools to install the Home Assistant on a system with OpenWrt installed. 
It provides the reduced version of HA with only minimal list of components included.
Additionally, it keeps MQTT, ESPHome, and ZHA components as they are widely used with smart home solutions.

Only specific HomeAssistant/OpenWRT combinations are supported. Please refer to the branches which are named by the OpenWRT version, to see which HA version is supported with which OpenWRT version.

It is distributed with a shell script that downloads and installs everything that required for a clean start.

Intended users: people who administer their OpenWrt router themselves. You need to be able to
log in with SSH as root, run shell commands, and edit configuration files; this README gives the
commands, but not an introduction to OpenWrt or Home Assistant.

### Requirements:
- OpenWrt 25.12.3 or newer installed
- 512 MB RAM, measured for HA 2026.2 on x86_64 without swap. With 256 MB the installation fails:
  the kernel kills pip while it builds a package. Once running, Home Assistant uses about 180 MB.
- Storage, measured for HA 2026.2 on x86_64 (the script checks the first two before it starts):
  - about 350 MB free for the Python venv (`--venv-dir`, ~300 MB when installed);
  - 512 MB free in the temporary build directory (`--tmp-dir`) during the installation;
    when both are on the same filesystem, the script requires the sum;
  - about 90 MB for the Python packages installed with `apk` on the root filesystem.

With the default paths everything lands on the internal flash, so most routers need an
[external disk](#installing-on-external-storage).

## Generic installation
Then, download the installer and run it. For instance:

```sh
ha_version=25.12
wget https://raw.githubusercontent.com/openlumi/homeassistant_on_openwrt/$ha_version/ha_install.sh -O - | sh
```

**Note:** the `25.12` branch is not published in the `openlumi` repository yet, so this URL
does not work at the moment. Until it is, download `ha_install.sh` from the branch you got this
README from, copy it to the router and run `sh ha_install.sh`.

After script prints `Done.` you have Home Assistant installed. 
Start the service or reboot the device to get it start automatically.
The web interface will be on 8123 port after all components load.

If Home Assistant crashes or the kernel kills it because the device is out of memory,
procd restarts it after 30 seconds. The init script sets Home Assistant's `oom_score_adj` to 800,
so that the kernel kills Home Assistant first, not network services such as `dnsmasq` or `hostapd`. procd stops trying after 5 runs in a row that each
lasted less than one hour. Home Assistant then stays down without further notice, so automations
(heating, locks, alarms) stop. Check for this with `logread -e homeassistant` and
`/etc/init.d/homeassistant status`. Fix the cause (usually memory, see the HA log), then run
`/etc/init.d/homeassistant start` again.

![Home Assistant](homeassistant.png)

The components that can be set up from the UI (config flows) are MQTT, ESPHome, Met.no and
Radio Browser, plus ZHA on the Lumi and GTW360 gateways.
After adding a component in the interface or via the config
HA could install dependencies and fails on finding them after installation.
In this case restarting HA could work.

Other components are not tested and may require additional changed in 
requirement versions or Python libraries.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 10 | Unknown option or missing option value |
| 11 | Home Assistant (or HASS Configurator) is still running |
| 12 | Not enough free disk space |
| 13 | No Home Assistant release found for the supported major version |
| 14 | A path option is not an absolute path of safe characters (`A-Z a-z 0-9 . _ / + -`, not `/`) |
| 15 | A non-default directory does not exist, for example because the external disk is not mounted |
| 16 | A patch of the Home Assistant source did not apply; the installer does not match the downloaded Home Assistant release. Please report it |
| other | A command failed; see the output above |

## Upgrading an existing installation

Re-run the install script to get fixes from this repository (see [Changelog](#changelog)).
Your configuration is kept: the script generates `configuration.yaml` only if it does not exist yet.

1. Stop Home Assistant. The script refuses to run while it is running, and Home Assistant
   needs a few seconds to exit; wait until `pgrep -f bin/hass` prints nothing:
   ```sh
   /etc/init.d/homeassistant stop
   /etc/init.d/hass-configurator stop   # only if you installed it
   ```
2. Re-run the script. Options you don't give are taken from the existing installation:
   `--venv-dir`, `--config-dir` and `--log-file` from `/etc/init.d/homeassistant`, and HASS
   Configurator stays installed if it was. Give an option only to change it; for example,
   `--no-configurator` removes HASS Configurator. A different `--venv-dir` installs a second
   venv and rewrites `/etc/init.d/homeassistant` to use it; the old venv stays on disk.
   The script replaces the venv completely on every run; the config directory is not touched.
3. Start Home Assistant again:
   ```sh
   /etc/init.d/homeassistant start
   ```

### After a sysupgrade

A sysupgrade to a newer OpenWrt release removes the Python packages installed with `apk` and
`/etc/init.d/homeassistant`. A venv on an external disk survives, but it no longer works,
because it uses the system Python. Re-run the script as described in
[Upgrading](#upgrading-an-existing-installation), but give the same options as for the first
installation again: the init script they would be taken from is gone.

### Migrating from an OpenWrt 23.05 installation

The 23.05 version installed Home Assistant into the system Python with `opkg`. There is no
in-place upgrade; install it fresh on OpenWrt 25.12 and keep your configuration:

1. Stop Home Assistant and back up the config directory (default `/etc/homeassistant`), for
   example `tar -czf /tmp/ha-config.tar.gz /etc/homeassistant` and copy the file off the router.
2. A sysupgrade keeps only the files listed in `/etc/sysupgrade.conf` (and the standard
   configuration). Add `/etc/homeassistant/` there, or restore the backup after the upgrade.
3. Sysupgrade the router to OpenWrt 25.12.3 or newer.
4. Run the install script. Pass `--with-configurator` if you used HASS Configurator: it is no
   longer installed by default. Otherwise remove the `panel_iframe:` block that points at port
   3218 from `configuration.yaml`.
5. Start Home Assistant. It migrates the old configuration to the new version on first start;
   check the log (`$HA_LOG_FILE`, default `/var/log/home-assistant.log`) for integrations that
   fail to load.

## Installing on external storage

Home Assistant requires roughly 300 MB of storage for its Python packages, plus a growing
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

Use ext4, not FAT or exFAT. FAT has no Unix file permissions, so every file on it, including
the HA tokens in `.storage/`, would be readable and writable by everyone. Keep in mind that
anyone with physical access to the disk can change the venv, which runs as root at boot.

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

Create the directories on the mounted disk. The install script refuses a non-default directory
that does not exist (exit code 15), so that it does not fill the internal flash when the disk is
not mounted:

```sh
mkdir -p /mnt/external/homeassistant /mnt/external/ha-config
```

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
| `--venv-dir` | `/opt/homeassistant` | Python venv (~300 MB of packages) |
| `--config-dir` | `/etc/homeassistant` | Config files (the SQLite database itself lives under `--db-url`) |
| `--db-url` | `sqlite:////tmp/homeassistant.db` | The recorder's SQLite database |

Both `--venv-dir` and `--config-dir` can also be set via environment variables (`HA_VENV_DIR`, `HA_CONFIG_DIR`);
`--db-url` via `HA_DB_URL`.
Run `sh ha_install.sh --help` to see all options.

### Temporary build directory

During installation `ha_install.sh` uses a temporary directory (`/root/tmp-ha` by default) for
downloading and unpacking packages. On devices with limited internal flash, this can fill the
primary disk. Point it at the external mount instead:

```sh
sh ha_install.sh \
  --tmp-dir   /mnt/external \
  --venv-dir  /mnt/external/homeassistant \
  --config-dir /mnt/external/ha-config
```

The flag takes precedence over the environment variable (`HA_TMP_DIR`); the environment
variable takes precedence over the default.

The script never deletes the given directory itself: it works in a new subdirectory
`ha-install.XXXXXX` inside it and removes only that subdirectory (and leftovers of earlier
aborted runs with the same prefix). Using the mount point itself, e.g. `--tmp-dir /mnt/external`,
is therefore safe.


## Feature support

### Core platform

All standard HA platform features are available:
automations, scripts, scenes, schedules, blueprints, templates, groups, helpers
(input booleans, numbers, selects, text, counters, timers, date/time),
todo lists, shopping list, person tracking, zones, tags, alerts, webhooks,
Python scripts, dashboard (Lovelace), history, logbook, energy dashboard, and backup.

The recorder uses SQLite. The default configuration stores the database in `/tmp` (RAM, cleared on reboot).
Pass `--db-url` (or set `HA_DB_URL`) to the install script to point the generated `configuration.yaml`
at a persistent path instead, e.g.:

```sh
sh ha_install.sh --db-url 'sqlite:////mnt/external/ha-config/homeassistant.db'
```

This only takes effect on first install, when `configuration.yaml` is generated; on existing
installs, edit `db_url` in the `recorder:` block directly.

Only SQLite is tested. `configuration.yaml` is readable by all users on the router, so do not put
a database password into `--db-url`; use `db_url: !secret recorder_db_url` with the URL in
`secrets.yaml` (mode 0600) instead.

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

The install script can optionally install and enable the following tool, which is not part of HA core:

| Tool | Port | Notes |
|---|---|---|
| [hass-configurator](https://github.com/danielperna84/hass-configurator) | 3218 | Web-based config file editor; verified working. Not authenticated on its own — only enable it on a trusted network. |

It is **disabled by default**. It runs as root, has no login, and listens on all interfaces:
everyone who can reach port 3218 can edit any file on the router, including `/etc/init.d/*`,
and so run commands as root. Enable it only on a network where you trust every device, with
`--with-configurator` (or `HA_INSTALL_CONFIGURATOR=1`):

```sh
sh ha_install.sh --with-configurator
```

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
The paths below use the defaults (`--venv-dir /opt/homeassistant`, Python 3.13);
adjust them if you installed elsewhere.

Download the source archive of the installed version from PyPI
(`https://pypi.org/project/homeassistant/<version>/#files`; the version is shown in the HA UI),
extract it, and copy the required components to
`/opt/homeassistant/lib/python3.13/site-packages/homeassistant/components`.
If the component uses the frontend wizard, also uncomment the corresponding line in
`/opt/homeassistant/lib/python3.13/site-packages/homeassistant/generated/config_flows.py`.
Both changes are lost when you re-run the install script.

Or create a `custom_components` directory in the config directory (default `/etc/homeassistant`)
and copy the component there. This survives a re-run.

Install the requirements from the component's `manifest.json` into the venv with
`/opt/homeassistant/bin/pip install ...` to check that they install and don't need
pre-compiled C libraries. Prefer packages from the OpenWrt feed (`apk add python3-...`)
when they exist; the venv sees them. Otherwise you have to cross-compile the dependency.

If a dependency is already installed (via `apk` or `pip`), you may need to relax the strict
version in `manifest.json` or remove the version.

## Code testing

The code has been tested with OpenWRT VMs on x86_64 and aarch64 architectures.
Reproducible tests are described in [tests/README.adoc](tests/README.adoc).

## Changelog

Versioning: each branch is named after the OpenWrt release it supports (e.g. `25.12`) and installs
one Home Assistant major version (`HOMEASSISTANT_MAJOR_VERSION` in `ha_install.sh`).
There are no release tags; entries below are dated and apply to the branch they are on.

### 2026-11-11

- Fixed: re-running the script over an existing installation (the upgrade path) aborted
  because the venv already existed. Every run now replaces the venv; the config is kept.
- Fixed: `--tmp-dir` deleted the given directory itself. The script now works in an
  `ha-install.*` subdirectory and deletes only that.
- Changed: path options must be absolute paths of plain characters (exit code 14 otherwise).
  The script checks free space for the venv as well, and uses documented exit codes
  (see [Exit codes](#exit-codes)).
- Fixed: Home Assistant memory grew steadily (about 15 MiB/h) until the kernel killed it.
  The installer replaced Home Assistant's size-limited caches with unlimited ones; it now installs
  OpenWrt's `python3-lru-dict` package instead.
  Installations made before this fix keep leaking: [upgrade](#upgrading-an-existing-installation) them by re-running the script.
- Fixed: installation stopped with a timeout while downloading hass-nabucasa on OpenWrt 25.12.
  It is now downloaded from PyPI instead of github.com.
- Fixed: a re-run without `--with-configurator` left HASS Configurator enabled at boot. It now
  removes its init script.
- Changed: a new configuration no longer sets the Google Translate TTS language to Russian;
  Home Assistant's default (English) applies.
- Changed: when Home Assistant is running, the script prints the commands to stop it. On a
  re-run it says that `configuration.yaml` is kept and `--db-url` has no effect.
- Changed: the kernel now kills Home Assistant first when memory runs out (`oom_score_adj` 800),
  instead of possibly `dnsmasq` or `hostapd`.
- Changed: the script stops (exit code 16) when one of its patches of the Home Assistant source
  no longer applies, instead of installing a Home Assistant with broken integrations.
- Changed: the RAM requirement is now 512 MB (was 256 MB, which is not enough for the
  installation; measured in a VM).
- Changed: a re-run takes `--venv-dir`, `--config-dir`, `--log-file` and the HASS Configurator
  choice from the existing installation when they are not given.
- Changed: a non-default `--tmp-dir`, `--venv-dir`, `--config-dir` or log-file directory must
  exist (exit code 15 otherwise), so an unmounted external disk is no longer filled on flash.

### 2026-05 to 2026-10: OpenWrt 25.12

Migration of the installer from OpenWrt 23.05 to 25.12.3 (see
[Migrating from an OpenWrt 23.05 installation](#migrating-from-an-openwrt-2305-installation)):

- Home Assistant is installed into its own Python venv (`--venv-dir`), on top of the system
  Python packages from `apk`, instead of into the system Python with `opkg`.
- New options: `--tmp-dir`, `--venv-dir`, `--config-dir`, `--log-file`, `--db-url`,
  `--with-configurator`/`--no-configurator`, and the matching environment variables.
- HASS Configurator is no longer installed by default.
- procd restarts Home Assistant after a crash or an out-of-memory kill.
- The generated configuration includes a `history:` block.
