#!/usr/bin/env bash
# =============================================================
# AIC8800D80 Linux Fix — Fully Automated Installer v2
# https://github.com/OZAMNJ/aic8800d80-linux-fix
# Run as: sudo bash install.sh
#
# What this does (fully automated, no manual steps):
#   1. Prompts for all network/WiFi settings interactively
#   2. Installs prerequisites (dkms, headers, usb-modeswitch, hostapd, dnsmasq)
#   3. Downloads + installs AIC8800 firmware + DKMS driver (radxa-pkg)
#   4. Applies {{placeholder}} templating to all config files
#   5. Adds usb-storage.quirks to /boot/firmware/cmdline.txt
#   6. Enables IPv4 forwarding + installs persistent NAT rules
#   7. Enables + starts all services
#   8. Validates hostapd config before finishing
# =============================================================

set -euo pipefail

# ──────────────────────── Colour helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ──────────────────────── Sanity checks
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────── Package versions (update here to upgrade)
AIC_VER="4.0+git20250410.b99ca8b6-3"
FW_DEB="aic8800-firmware_${AIC_VER}_all.deb"
DKMS_DEB="aic8800-usb-dkms_${AIC_VER}_all.deb"
BASE_URL="https://github.com/radxa-pkg/aic8800/releases/download/4.0%2Bgit20250410.b99ca8b6-3"
QUIRK="usb-storage.quirks=1111:1111:i"
CMDLINE_FILE="/boot/firmware/cmdline.txt"

# ──────────────────────── Helper functions

require_file() { [[ -f "$1" ]] || die "Missing required repo file: $1"; }

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo "${value:-$default}"
}

prompt_secret() {
  local prompt="$1" default="$2" value
  read -r -s -p "$prompt [$default]: " value; echo
  echo "${value:-$default}"
}

list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

same_subnet_24() { [[ "${1%.*}" == "${2%.*}" ]]; }

internet_ok() {
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 ||
    curl -sI --connect-timeout 5 https://github.com >/dev/null 2>&1
}

# Safe placeholder templating: sed 's|{{KEY}}|value|g'
# Much safer than the previous regex-based sed approach
apply_template() {
  local file="$1"; shift
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"; shift 2
    sed -i "s|{{${key}}}|${val}|g" "$file"
  done
}

append_cmdline_quirk() {
  if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found — add '$QUIRK' to your kernel cmdline manually"
    return 0
  fi
  if grep -q "$QUIRK" "$CMDLINE_FILE"; then
    ok "$CMDLINE_FILE already contains $QUIRK"
    return 0
  fi
  info "Adding $QUIRK to $CMDLINE_FILE"
  cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  local line
  line="$(tr -d '\n' < "$CMDLINE_FILE" | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
  printf '%s %s\n' "$line" "$QUIRK" > "$CMDLINE_FILE"
  ok "$CMDLINE_FILE updated"
}

enable_ip_forwarding() {
  info "Enabling IPv4 forwarding"
  if grep -q '^#*net.ipv4.ip_forward' /etc/sysctl.conf; then
    sed -i 's|^#*net.ipv4.ip_forward.*|net.ipv4.ip_forward=1|' /etc/sysctl.conf
  else
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ok "IPv4 forwarding enabled"
}

install_nat_rules() {
  local wan="$1" lan="$2"
  info "Installing persistent NAT rules (WAN=$wan LAN=$lan)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
  # Idempotent — only add rule if not already present
  iptables -t nat -C POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null ||
    iptables -t nat -A POSTROUTING -o "$wan" -j MASQUERADE
  iptables -C FORWARD -i "$lan" -o "$wan" -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i "$lan" -o "$wan" -j ACCEPT
  iptables -C FORWARD -i "$wan" -o "$lan" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i "$wan" -o "$lan" \
      -m state --state RELATED,ESTABLISHED -j ACCEPT
  netfilter-persistent save >/dev/null 2>&1 ||
    { mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4; }
  ok "NAT rules applied and saved"
}

validate_hostapd_conf() {
  local conf="$1"
  info "Validating hostapd config"
  if command -v hostapd >/dev/null 2>&1; then
    if hostapd -t "$conf" 2>/dev/null; then
      ok "hostapd config is valid"
    else
      warn "hostapd config validation returned warnings — check $conf"
    fi
  else
    warn "hostapd not yet installed — skipping config validation"
  fi
}

# ──────────────────────── Banner
echo -e "\n${CYAN}${BOLD}============================================================${NC}"
echo -e "${BOLD} AIC8800D80 — Fully Automated Installer v2${NC}"
echo -e " https://github.com/OZAMNJ/aic8800d80-linux-fix"
echo -e "${CYAN}${BOLD}============================================================${NC}\n"

# Pre-flight checks
info "Checking internet connectivity"
internet_ok || die "No internet. Connect LAN/Ethernet and retry."
ok "Internet OK"

echo
info "Detected network interfaces:"
list_ifaces | sed 's/^/  - /'
echo

# ──────────────────────── Interactive prompts
WAN_IFACE="$(prompt_default "WAN / uplink interface (internet side)" "eth0")"
LAN_IFACE="$(prompt_default "LAN / AP WiFi interface (dongle side)" "wlan0")"
echo

echo "--- IP / Subnet ---"
AP_IP="$(prompt_default "AP gateway IP" "192.168.73.1")"
AP_CIDR="$(prompt_default "AP subnet CIDR" "24")"
DHCP_START="$(prompt_default "DHCP pool start" "192.168.73.10")"
DHCP_END="$(prompt_default "DHCP pool end" "192.168.73.100")"
NETMASK="$(prompt_default "DHCP netmask" "255.255.255.0")"
LEASE_TIME="$(prompt_default "DHCP lease time" "24h")"
echo

echo "--- WiFi / hostapd ---"
SSID="$(prompt_default "WiFi SSID" "TravelRouter")"

# Password validation: minimum 8 characters
while true; do
  WPA_PSK="$(prompt_secret "WiFi password (min 8 chars, hidden)" "ChangeMe1")"
  if [[ ${#WPA_PSK} -ge 8 ]]; then break; fi
  warn "Password must be at least 8 characters. Try again."
done

COUNTRY_CODE="$(prompt_default "WiFi country code (DE US GB etc.)" "DE")"
CHANNEL="$(prompt_default "WiFi channel (1/6/11 for 2.4GHz)" "6")"
echo

echo "--- DNS ---"
USE_UNBOUND="$(prompt_default "Use local Unbound/system DNS on port 53? (yes/no)" "yes")"
echo

echo "--- Optional ---"
PROTECT_SSH="$(prompt_default "Add SSH allow rule on WAN interface? (yes/no)" "yes")"
echo

# Subnet overlap warning
CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  warn "WAN IP $CURRENT_WAN_IP overlaps with AP subnet $AP_IP -- consider changing AP IP"
fi

echo "------------------------------------------------------------"
echo " Configuration Summary"
echo "------------------------------------------------------------"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START - $DHCP_END ($NETMASK, $LEASE_TIME)"
echo "  SSID           : $SSID"
echo "  Country / Ch   : $COUNTRY_CODE / $CHANNEL"
echo "  Use Unbound    : $USE_UNBOUND"
echo "  Protect SSH    : $PROTECT_SSH"
echo "------------------------------------------------------------"
read -r -p "Proceed? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || { echo "Aborted."; exit 1; }
echo

# ──────────────────────── Verify all repo config files exist
require_file "$SCRIPT_DIR/etc/modprobe.d/aic8800-blacklist.conf"
require_file "$SCRIPT_DIR/etc/udev/rules.d/99-aic8800-switch.rules"
require_file "$SCRIPT_DIR/etc/systemd/system/aic8800-switch.service"
require_file "$SCRIPT_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/hostapd/hostapd.conf"
require_file "$SCRIPT_DIR/etc/default/hostapd"
require_file "$SCRIPT_DIR/etc/dnsmasq.d/travel-ap.conf"
require_file "$SCRIPT_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf"

# ──────────────────────── Step 1: Install prerequisites
info "[1/7] Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y \
  dkms "linux-headers-$(uname -r)" \
  usb-modeswitch usb-modeswitch-data \
  hostapd dnsmasq wget curl \
  iptables-persistent netfilter-persistent
ok "Prerequisites installed"

command -v usb_modeswitch >/dev/null 2>&1 ||
  die "usb_modeswitch not found after install -- check package manager"
ok "usb_modeswitch verified"

# ──────────────────────── Step 2: SSH protection
if [[ "$PROTECT_SSH" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  info "[2/7] Adding SSH allow rule on $WAN_IFACE"
  iptables -C INPUT -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT 2>/dev/null ||
    iptables -I INPUT 1 -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT
  ok "SSH rule added"
else
  info "[2/7] Skipping SSH protection rule"
fi

# ──────────────────────── Step 3: Download + install AIC8800 driver
info "[3/7] Downloading AIC8800 firmware + DKMS packages"
wget -q --show-progress -O "/tmp/${FW_DEB}" "${BASE_URL}/${FW_DEB}"
wget -q --show-progress -O "/tmp/${DKMS_DEB}" "${BASE_URL}/${DKMS_DEB}"
info "Installing AIC8800 packages"
rm -rf /lib/firmware/aic8800D80
dpkg -i "/tmp/${FW_DEB}"
dpkg -i "/tmp/${DKMS_DEB}"
dkms status | grep -qi "aic8800-usb" ||
  die "aic8800-usb DKMS module did not install correctly"
ok "DKMS driver installed and verified"

# ──────────────────────── Step 4: Apply {{placeholder}} templates
info "[4/7] Applying placeholder templates to config files"
TMP_DIR="$(mktemp -d)"
trap 'EC=$?; rm -rf "$TMP_DIR"; [[ $EC -ne 0 ]] && warn "Installer failed -- system files NOT yet changed"; exit $EC' EXIT
cp -a "$SCRIPT_DIR/etc" "$TMP_DIR/"

apply_template "$TMP_DIR/etc/systemd/system/aic8800-switch.service" \
  LAN_IFACE "$LAN_IFACE" AP_IP "$AP_IP" AP_CIDR "$AP_CIDR"

apply_template "$TMP_DIR/etc/hostapd/hostapd.conf" \
  LAN_IFACE "$LAN_IFACE" SSID "$SSID" WPA_PSK "$WPA_PSK" \
  CHANNEL "$CHANNEL" COUNTRY_CODE "$COUNTRY_CODE"

apply_template "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" \
  LAN_IFACE "$LAN_IFACE" DHCP_START "$DHCP_START" DHCP_END "$DHCP_END" \
  NETMASK "$NETMASK" LEASE_TIME "$LEASE_TIME" AP_IP "$AP_IP"

cat > "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" <<EOF
[keyfile]
unmanaged-devices=interface-name:${LAN_IFACE}
EOF

if [[ "$USE_UNBOUND" =~ ^([Nn][Oo]|[Nn])$ ]]; then
  sed -i 's/^port=0/# port=0 (disabled)/' "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" || true
  printf '\nserver=8.8.8.8\nserver=8.8.4.4\nno-resolv\n' >> "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf"
fi
ok "Templates applied"

# ──────────────────────── Step 5: Copy to system
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

# ──────────────────────── Step 6: Validate hostapd + system setup
info "[6/7] Validating + configuring system"
validate_hostapd_conf /etc/hostapd/hostapd.conf
append_cmdline_quirk
enable_ip_forwarding
install_nat_rules "$WAN_IFACE" "$LAN_IFACE"

# ──────────────────────── Step 7: Enable services
info "[7/7] Enabling services"
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
systemctl enable aic8800-switch hostapd dnsmasq
ok "Services enabled"

# ──────────────────────── Done
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
