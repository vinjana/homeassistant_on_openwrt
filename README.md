# Homeassistant on OpenWrt

This repo provides tools to install the latest version of Home Assistant. (2024.3.x)
on a system with OpenWrt 23.05+ installed. It provides the reduced version of HA with only minimal list of components 
included. Additionally, it keeps MQTT, ESPHome, and ZHA components as they are 
widely used with smart home solutions.

It is distributed with a shell script that downloads and installs everything that required for a clean start.

### Requirements:
- 256 MB storage space
- 256 MB RAM
- OpenWrt 23.05.0 or newer installed


## Generic installation
Then, download the installer and run it.

```sh
wget https://raw.githubusercontent.com/openlumi/homeassistant_on_openwrt/23.05/ha_install.sh -O - | sh
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
requirement versions or python libraries.

## Installing on external storage

Home Assistant requires roughly 250 MB of storage for its Python packages.
If your router's internal flash is too small, mount an external disk and bind-mount
it over the Python site-packages directory **before** running `ha_install.sh`.

This approach keeps the router's core function (networking, firewall) on internal flash
and only the HA packages on the external disk.
If the external disk fails, the router keeps routing and HA simply fails to start —
recovering is a matter of attaching a new disk and re-running the install script.

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

Create mount points and mount the disk:

```sh
mkdir -p /mnt/external
mount /dev/sda1 /mnt/external
mkdir -p /mnt/external/python-packages
```

Determine your Python version:

```sh
python3 --version    # e.g. Python 3.13.x
```

Bind-mount the site-packages directory so pip writes to the external disk:

```sh
mount --bind /mnt/external/python-packages /usr/lib/python3.13/site-packages
```

Replace `3.13` with the actual major.minor version if different.

Make both mounts persistent across reboots by adding them to `/etc/fstab`:

```
/dev/sda1                          /mnt/external                ext4  defaults          0 0
/mnt/external/python-packages      /usr/lib/python3.13/site-packages  none  bind,nofail  0 0
```

The `nofail` option on the bind mount ensures the router still boots cleanly if the
external disk is absent (HA will not start, but routing and networking are unaffected).

Now proceed with the normal installation below.


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
