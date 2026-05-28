#!/usr/bin/env bash
# AIC8800D80 Linux Fix — Quick Install Script
# Copies all config files from this repo to the correct system locations.
# Run as: sudo bash install.sh
#
# IMPORTANT: Edit the files in etc/ to match your network settings BEFORE running this.
# Specifically change:
#   - etc/systemd/system/aic8800-switch.service  → IP address (192.168.73.1)
#   - etc/hostapd/hostapd.conf                   → SSID, password, country_code, channel
#   - etc/dnsmasq.d/travel-ap.conf               → IP addresses
#
# See README.md for full instructions.

set -e

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo bash install.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing config files..."

mkdir -p /etc/modprobe.d
cp "$SCRIPT_DIR/etc/modprobe.d/aic8800-blacklist.conf" /etc/modprobe.d/

mkdir -p /etc/udev/rules.d
cp "$SCRIPT_DIR/etc/udev/rules.d/99-aic8800-switch.rules" /etc/udev/rules.d/

mkdir -p /etc/systemd/system
cp "$SCRIPT_DIR/etc/systemd/system/aic8800-switch.service" /etc/systemd/system/

mkdir -p /etc/systemd/system/hostapd.service.d
cp "$SCRIPT_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf" /etc/systemd/system/hostapd.service.d/

mkdir -p /etc/systemd/system/dnsmasq.service.d
cp "$SCRIPT_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf" /etc/systemd/system/dnsmasq.service.d/

mkdir -p /etc/hostapd
cp "$SCRIPT_DIR/etc/hostapd/hostapd.conf" /etc/hostapd/

cp "$SCRIPT_DIR/etc/default/hostapd" /etc/default/hostapd

mkdir -p /etc/dnsmasq.d
cp "$SCRIPT_DIR/etc/dnsmasq.d/travel-ap.conf" /etc/dnsmasq.d/

mkdir -p /etc/NetworkManager/conf.d
cp "$SCRIPT_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" /etc/NetworkManager/conf.d/

echo "==> Reloading systemd and udev..."
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u

echo "==> Enabling services..."
systemctl enable aic8800-switch hostapd dnsmasq

echo ""
echo "==> Done! Next steps:"
echo "    1. Edit /etc/hostapd/hostapd.conf (SSID, password, country_code)"
echo "    2. Edit /etc/systemd/system/aic8800-switch.service (IP address)"
echo "    3. Edit /boot/firmware/cmdline.txt — add: usb-storage.quirks=1111:1111:i"
echo "    4. Install DKMS driver (see README Step 3)"
echo "    5. sudo reboot"
