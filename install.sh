#!/usr/bin/env bash
# AIC8800D80 Linux Fix — Fully Interactive Installer
# Run as: sudo bash install.sh

set -euo pipefail

AIC_VER="4.0+git20250410.b99ca8b6-3"
FW_DEB="aic8800-firmware_${AIC_VER}_all.deb"
DKMS_DEB="aic8800-usb-dkms_${AIC_VER}_all.deb"
BASE_URL="https://github.com/radxa-pkg/aic8800/releases/download/4.0%2Bgit20250410.b99ca8b6-3"
QUIRK="usb-storage.quirks=1111:1111:i"
CMDLINE_FILE="/boot/firmware/cmdline.txt"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  echo "Use: sudo bash install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info(){ echo "[INFO] $*"; }
ok(){ echo "[ OK ] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[ERR ] $*"; exit 1; }

require_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Missing required file: $f"
}

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

prompt_secret_default() {
  local prompt="$1" default="$2" value
  read -r -s -p "$prompt [$default]: " value
  echo
  echo "${value:-$default}"
}

list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

same_subnet_24() {
  local ip1="$1" ip2="$2"
  [[ "${ip1%.*}" == "${ip2%.*}" ]]
}

internet_ok() {
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || curl -I --connect-timeout 5 https://github.com >/dev/null 2>&1
}

append_cmdline_quirk() {
  if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found. Add this manually after install: $QUIRK"
    return 0
  fi

  if grep -q "$QUIRK" "$CMDLINE_FILE"; then
    ok "cmdline.txt already contains $QUIRK"
    return 0
  fi

  info "Adding usb-storage quirk to $CMDLINE_FILE"
  cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  local current
  current="$(tr -d '\n' < "$CMDLINE_FILE" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  printf '%s %s\n' "$current" "$QUIRK" > "$CMDLINE_FILE"
  ok "cmdline.txt updated"
}

enable_ip_forwarding() {
  info "Enabling IPv4 forwarding"
  if grep -q '^#net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  elif ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ok "IPv4 forwarding enabled"
}

install_nat_rules() {
  local wan="$1" lan="$2"

  info "Installing persistent firewall packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true

  info "Applying NAT rules"
  iptables -t nat -C POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$wan" -j MASQUERADE

  iptables -C FORWARD -i "$lan" -o "$wan" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$lan" -o "$wan" -j ACCEPT

  iptables -C FORWARD -i "$wan" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$wan" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT

  info "Saving firewall rules"
  netfilter-persistent save >/dev/null 2>&1 || {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
  }
  ok "NAT rules installed"
}

validate_hostapd_conf() {
  local conf="$1"
  grep -q '^interface=' "$conf" || die "hostapd.conf missing interface="
  grep -q '^ssid=' "$conf" || die "hostapd.conf missing ssid="
  grep -q '^wpa_passphrase=' "$conf" || die "hostapd.conf missing wpa_passphrase="
  ok "hostapd.conf validated"
}

echo "============================================================"
echo " AIC8800D80 Fully Interactive Installer"
echo "============================================================"
echo "IMPORTANT:"
echo "  - Connect your Raspberry Pi to wired LAN/Ethernet first"
echo "  - Active internet is required to install packages and download"
echo "    the AIC8800 firmware/DKMS files from GitHub"
echo

internet_ok || die "No active internet connection detected. Connect LAN/Ethernet and retry."

info "Detected network interfaces:"
list_ifaces | sed 's/^/  - /'
echo

WAN_IFACE="$(prompt_default "WAN/uplink interface (must have internet)" "eth0")"
LAN_IFACE="$(prompt_default "LAN/AP WiFi interface" "wlan0")"
AP_IP="$(prompt_default "AP gateway IP" "192.168.73.1")"
AP_CIDR="$(prompt_default "AP subnet CIDR bits" "24")"
DHCP_START="$(prompt_default "DHCP start IP" "192.168.73.10")"
DHCP_END="$(prompt_default "DHCP end IP" "192.168.73.100")"
NETMASK="$(prompt_default "DHCP netmask" "255.255.255.0")"
LEASE_TIME="$(prompt_default "DHCP lease time" "24h")"
SSID="$(prompt_default "WiFi SSID" "TravelRouter")"
WPA_PSK="$(prompt_secret_default "WiFi password" "ChangeMe123")"
COUNTRY_CODE="$(prompt_default "WiFi country code" "DE")"
CHANNEL="$(prompt_default "WiFi channel (1/6/11 recommended)" "6")"
USE_UNBOUND="$(prompt_default "Use Unbound/system DNS on port 53? (yes/no)" "yes")"
PROTECT_SSH="$(prompt_default "Add SSH protection rule on WAN interface? (yes/no)" "yes")"

CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  warn "WAN IP $CURRENT_WAN_IP may overlap with AP subnet based on $AP_IP"
fi

echo "------------------------------------------------------------"
echo "Configuration summary"
echo "------------------------------------------------------------"
echo "WAN interface : $WAN_IFACE"
echo "LAN/AP iface  : $LAN_IFACE"
echo "AP gateway    : $AP_IP/$AP_CIDR"
echo "DHCP range    : $DHCP_START - $DHCP_END"
echo "SSID          : $SSID"
echo "Country code  : $COUNTRY_CODE"
echo "Channel       : $CHANNEL"
echo "Use Unbound   : $USE_UNBOUND"
echo "Protect SSH   : $PROTECT_SSH"
echo "------------------------------------------------------------"
read -r -p "Continue with these settings? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"

require_file "$SCRIPT_DIR/etc/modprobe.d/aic8800-blacklist.conf"
require_file "$SCRIPT_DIR/etc/udev/rules.d/99-aic8800-switch.rules"
require_file "$SCRIPT_DIR/etc/systemd/system/aic8800-switch.service"
require_file "$SCRIPT_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/hostapd/hostapd.conf"
require_file "$SCRIPT_DIR/etc/default/hostapd"
require_file "$SCRIPT_DIR/etc/dnsmasq.d/travel-ap.conf"
require_file "$SCRIPT_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf"

info "[1/7] Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dkms "linux-headers-$(uname -r)" usb-modeswitch hostapd dnsmasq wget curl
ok "Prerequisites installed"

if [[ "$PROTECT_SSH" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  info "[2/7] Installing SSH protection rule on $WAN_IFACE"
  apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
  iptables -C INPUT -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT
  iptables -C INPUT -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
  netfilter-persistent save >/dev/null 2>&1 || true
  ok "SSH protection installed"
else
  info "[2/7] Skipping SSH protection rule"
fi

info "[3/7] Downloading and installing AIC8800 firmware + DKMS"
wget -O "/tmp/${FW_DEB}" "${BASE_URL}/${FW_DEB}"
wget -O "/tmp/${DKMS_DEB}" "${BASE_URL}/${DKMS_DEB}"
rm -rf /lib/firmware/aic8800D80
dpkg -i "/tmp/${FW_DEB}"
dpkg -i "/tmp/${DKMS_DEB}"
dkms status | grep -q "aic8800-usb" || die "aic8800-usb DKMS did not install correctly"
ok "Firmware and DKMS installed"

info "[4/7] Preparing customized configs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cp -a "$SCRIPT_DIR/etc" "$TMP_DIR/"

sed -i \
  -e "s/^interface=.*/interface=${LAN_IFACE}/" \
  -e "s/^ssid=.*/ssid=${SSID}/" \
  -e "s/^channel=.*/channel=${CHANNEL}/" \
  -e "s/^wpa_passphrase=.*/wpa_passphrase=${WPA_PSK}/" \
  -e "s/^country_code=.*/country_code=${COUNTRY_CODE}/" \
  "$TMP_DIR/etc/hostapd/hostapd.conf"

sed -i \
  -e "s/^interface=.*/interface=${LAN_IFACE}/" \
  -e "s/^dhcp-range=.*/dhcp-range=${DHCP_START},${DHCP_END},${NETMASK},${LEASE_TIME}/" \
  -e "s/^dhcp-option=3,.*/dhcp-option=3,${AP_IP}/" \
  -e "s/^dhcp-option=6,.*/dhcp-option=6,${AP_IP}/" \
  "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf"

if [[ "$USE_UNBOUND" =~ ^([Nn][Oo]|[Nn])$ ]]; then
  sed -i 's/^port=0/# port=0 disabled by installer/' "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" || true
  cat >> "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" <<'EODNS'

server=8.8.8.8
server=8.8.4.4
no-resolv
EODNS
fi

cat > "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" <<EONM
[keyfile]
unmanaged-devices=interface-name:${LAN_IFACE}
EONM

sed -i \
  -e "s|ip addr add [0-9.]\\+/[0-9]\\+ dev wlan0|ip addr add ${AP_IP}/${AP_CIDR} dev ${LAN_IFACE}|" \
  -e "s|ip link set wlan0 up|ip link set ${LAN_IFACE} up|" \
  -e "s|iw dev wlan0 set power_save off|iw dev ${LAN_IFACE} set power_save off|" \
  "$TMP_DIR/etc/systemd/system/aic8800-switch.service"
ok "Configs customized"

info "[5/7] Installing config files to system"
mkdir -p /etc/modprobe.d && cp "$TMP_DIR/etc/modprobe.d/aic8800-blacklist.conf" /etc/modprobe.d/
mkdir -p /etc/udev/rules.d && cp "$TMP_DIR/etc/udev/rules.d/99-aic8800-switch.rules" /etc/udev/rules.d/
mkdir -p /etc/systemd/system && cp "$TMP_DIR/etc/systemd/system/aic8800-switch.service" /etc/systemd/system/
mkdir -p /etc/systemd/system/hostapd.service.d
cp "$TMP_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf" /etc/systemd/system/hostapd.service.d/
mkdir -p /etc/systemd/system/dnsmasq.service.d
cp "$TMP_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf" /etc/systemd/system/dnsmasq.service.d/
mkdir -p /etc/hostapd && cp "$TMP_DIR/etc/hostapd/hostapd.conf" /etc/hostapd/
cp "$TMP_DIR/etc/default/hostapd" /etc/default/hostapd
mkdir -p /etc/dnsmasq.d && cp "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" /etc/dnsmasq.d/
mkdir -p /etc/NetworkManager/conf.d && cp "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" /etc/NetworkManager/conf.d/
ok "Config files installed"

info "[6/7] Validating + configuring system"
validate_hostapd_conf /etc/hostapd/hostapd.conf
append_cmdline_quirk
enable_ip_forwarding
install_nat_rules "$WAN_IFACE" "$LAN_IFACE"
ok "System configuration complete"

info "[7/7] Enabling services"
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
systemctl enable aic8800-switch hostapd dnsmasq
ok "Services enabled"

echo
echo "============================================================"
echo " Installation complete!"
echo "============================================================"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START - $DHCP_END"
echo "  SSID           : $SSID"
echo "  Country / Ch   : $COUNTRY_CODE / $CHANNEL"
echo
echo "Next: reboot the system"
echo "  sudo reboot"
echo
echo "After reboot, verify:"
echo "  1. lsusb | grep a69c                  (expect a69c:8d81)"
echo "  2. ip addr show $LAN_IFACE             (expect $AP_IP)"
echo "  3. systemctl status aic8800-switch hostapd dnsmasq --no-pager"
echo "  4. dkms status                         (expect aic8800-usb installed)"
echo "  5. ping -c3 8.8.8.8                    (from a client connected via WiFi)"
echo "============================================================"
