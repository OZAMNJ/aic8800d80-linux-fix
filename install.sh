#!/usr/bin/env bash
# AIC8800D80 Linux Fix — Interactive Installer
# Prompts for all WAN/LAN/AP/DHCP/WiFi settings before installing.
# Run as: sudo bash install.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo bash install.sh)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "Missing required file: $f"; exit 1; }
}

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

prompt_secret() {
  local prompt="$1" default="$2" value
  read -r -s -p "$prompt [$default]: " value
  echo
  echo "${value:-$default}"
}

list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

same_subnet_24() {
  [[ "${1%.*}" == "${2%.*}" ]]
}

echo "============================================================"
echo " AIC8800D80 — Interactive Installer"
echo " https://github.com/OZAMNJ/aic8800d80-linux-fix"
echo "============================================================"
echo
echo "Detected network interfaces:"
list_ifaces | sed 's/^/  - /'
echo

WAN_IFACE="$(prompt_default "WAN / uplink interface (internet side)" "eth0")"
LAN_IFACE="$(prompt_default "LAN / AP WiFi interface (hotspot side)" "wlan0")"
echo

echo "--- IP / Subnet settings ---"
AP_IP="$(prompt_default "AP gateway IP" "192.168.73.1")"
AP_CIDR="$(prompt_default "AP subnet CIDR prefix length" "24")"
DHCP_START="$(prompt_default "DHCP pool start IP" "192.168.73.10")"
DHCP_END="$(prompt_default "DHCP pool end IP" "192.168.73.100")"
NETMASK="$(prompt_default "DHCP netmask" "255.255.255.0")"
LEASE_TIME="$(prompt_default "DHCP lease time" "24h")"
echo

echo "--- WiFi / hostapd settings ---"
SSID="$(prompt_default "WiFi SSID" "TravelRouter")"
WPA_PSK="$(prompt_secret "WiFi password (hidden)" "ChangeMe123")"
COUNTRY_CODE="$(prompt_default "WiFi country code (ISO 3166-1 alpha-2, e.g. DE US GB)" "DE")"
CHANNEL="$(prompt_default "WiFi channel (1/6/11 recommended for 2.4 GHz)" "6")"
echo

echo "--- DNS settings ---"
USE_UNBOUND="$(prompt_default "Use local Unbound/system resolver on port 53? (yes/no)" "yes")"
echo

# Subnet overlap warning
CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  echo "WARNING: WAN interface $WAN_IFACE has IP $CURRENT_WAN_IP which overlaps"
  echo "         with your chosen AP subnet ($AP_IP). Consider a different AP range."
  echo
fi

echo "------------------------------------------------------------"
echo " Configuration summary"
echo "------------------------------------------------------------"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START - $DHCP_END ($NETMASK, lease $LEASE_TIME)"
echo "  SSID           : $SSID"
echo "  Country code   : $COUNTRY_CODE"
echo "  WiFi channel   : $CHANNEL"
echo "  Use Unbound    : $USE_UNBOUND"
echo "------------------------------------------------------------"
read -r -p "Continue with these settings? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || { echo "Aborted."; exit 1; }
echo

# Verify all source files exist
require_file "$SCRIPT_DIR/etc/modprobe.d/aic8800-blacklist.conf"
require_file "$SCRIPT_DIR/etc/udev/rules.d/99-aic8800-switch.rules"
require_file "$SCRIPT_DIR/etc/systemd/system/aic8800-switch.service"
require_file "$SCRIPT_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/hostapd/hostapd.conf"
require_file "$SCRIPT_DIR/etc/default/hostapd"
require_file "$SCRIPT_DIR/etc/dnsmasq.d/travel-ap.conf"
require_file "$SCRIPT_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf"

# Work in a temp dir so originals are never modified
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -a "$SCRIPT_DIR/etc" "$TMP_DIR/"

# ---- Patch hostapd.conf ----
sed -i \
  -e "s/^interface=.*/interface=${LAN_IFACE}/" \
  -e "s/^ssid=.*/ssid=${SSID}/" \
  -e "s/^channel=.*/channel=${CHANNEL}/" \
  -e "s/^wpa_passphrase=.*/wpa_passphrase=${WPA_PSK}/" \
  -e "s/^country_code=.*/country_code=${COUNTRY_CODE}/" \
  "$TMP_DIR/etc/hostapd/hostapd.conf"

# ---- Patch dnsmasq ----
sed -i \
  -e "s/^interface=.*/interface=${LAN_IFACE}/" \
  -e "s/^dhcp-range=.*/dhcp-range=${DHCP_START},${DHCP_END},${NETMASK},${LEASE_TIME}/" \
  -e "s/^dhcp-option=3,.*/dhcp-option=3,${AP_IP}/" \
  -e "s/^dhcp-option=6,.*/dhcp-option=6,${AP_IP}/" \
  "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf"

if [[ "$USE_UNBOUND" =~ ^([Nn][Oo]|[Nn])$ ]]; then
  sed -i 's/^port=0/# port=0 (disabled — using upstream DNS)/' \
    "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" || true
  printf '\nserver=8.8.8.8\nserver=8.8.4.4\nno-resolv\n' \
    >> "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf"
fi

# ---- Patch NetworkManager unmanaged-devices ----
cat > "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" <<EOF
[keyfile]
unmanaged-devices=interface-name:${LAN_IFACE}
EOF

# ---- Patch aic8800-switch.service ----
sed -i \
  -e "s|ip addr add [0-9.]\+/[0-9]\+ dev wlan0|ip addr add ${AP_IP}/${AP_CIDR} dev ${LAN_IFACE}|" \
  -e "s|ip link set wlan0 up|ip link set ${LAN_IFACE} up|" \
  -e "s|iw dev wlan0 set power_save off|iw dev ${LAN_IFACE} set power_save off|" \
  "$TMP_DIR/etc/systemd/system/aic8800-switch.service"

# ---- Copy to system ----
echo "==> Installing customized config files..."

mkdir -p /etc/modprobe.d
cp "$TMP_DIR/etc/modprobe.d/aic8800-blacklist.conf" /etc/modprobe.d/

mkdir -p /etc/udev/rules.d
cp "$TMP_DIR/etc/udev/rules.d/99-aic8800-switch.rules" /etc/udev/rules.d/

mkdir -p /etc/systemd/system
cp "$TMP_DIR/etc/systemd/system/aic8800-switch.service" /etc/systemd/system/

mkdir -p /etc/systemd/system/hostapd.service.d
cp "$TMP_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf" \
   /etc/systemd/system/hostapd.service.d/

mkdir -p /etc/systemd/system/dnsmasq.service.d
cp "$TMP_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf" \
   /etc/systemd/system/dnsmasq.service.d/

mkdir -p /etc/hostapd
cp "$TMP_DIR/etc/hostapd/hostapd.conf" /etc/hostapd/
cp "$TMP_DIR/etc/default/hostapd" /etc/default/hostapd

mkdir -p /etc/dnsmasq.d
cp "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" /etc/dnsmasq.d/

mkdir -p /etc/NetworkManager/conf.d
cp "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" /etc/NetworkManager/conf.d/

echo "==> Reloading systemd and udev..."
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u 2>/dev/null || true

echo "==> Enabling services..."
systemctl enable aic8800-switch hostapd dnsmasq

echo
echo "==> NAT / IP forwarding — add these lines to /etc/rc.local or run manually:"
echo "    sysctl -w net.ipv4.ip_forward=1"
echo "    iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE"
echo "    iptables -A FORWARD -i ${LAN_IFACE} -o ${WAN_IFACE} -j ACCEPT"
echo "    iptables -A FORWARD -i ${WAN_IFACE} -o ${LAN_IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT"
echo
echo "==> IMPORTANT: Add this to /boot/firmware/cmdline.txt on the same single line:"
echo "    usb-storage.quirks=1111:1111:i"
echo
echo "============================================================"
echo " Installation complete!"
echo "============================================================"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START - $DHCP_END"
echo "  SSID           : $SSID"
echo "  Country        : $COUNTRY_CODE  Channel: $CHANNEL"
echo
echo "Next steps:"
echo "  1. Install the DKMS driver packages listed in README.md"
echo "  2. Add usb-storage.quirks=1111:1111:i to /boot/firmware/cmdline.txt"
echo "  3. Set up NAT rules shown above (or use nftables equivalent)"
echo "  4. Reboot"
echo "  5. Verify: lsusb | grep a69c"
echo "  6. Verify: ip addr show $LAN_IFACE"
echo "  7. Verify: systemctl status aic8800-switch hostapd dnsmasq"
echo "============================================================"
