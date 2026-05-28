#!/usr/bin/env bash
# AIC8800D80 Linux Fix — FULLY AUTOMATED Installer
# Handles: interactive config, DKMS driver install, cmdline.txt, NAT, service setup, verification
# Run as: sudo bash install.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash install.sh"; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_file() { [[ -f "$1" ]] || { err "Missing: $1"; exit 1; }; }

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

# ============================================================
echo -e "\n${CYAN}============================================================${NC}"
echo -e " AIC8800D80 — Full Automated Installer"
echo -e " https://github.com/OZAMNJ/aic8800d80-linux-fix"
echo -e "${CYAN}============================================================${NC}\n"

echo "Detected network interfaces:"
list_ifaces | sed 's/^/  - /'
echo

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
WPA_PSK="$(prompt_secret "WiFi password (hidden)" "ChangeMe123")"
COUNTRY_CODE="$(prompt_default "WiFi country code (e.g. DE US GB)" "DE")"
CHANNEL="$(prompt_default "WiFi channel (1/6/11)" "6")"
echo

echo "--- DNS ---"
USE_UNBOUND="$(prompt_default "Use local Unbound/system DNS on port 53? (yes/no)" "yes")"
echo

CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  warn "WAN IP $CURRENT_WAN_IP may overlap with AP subnet $AP_IP — consider changing AP IP"
fi

echo "------------------------------------------------------------"
echo " Configuration Summary"
echo "------------------------------------------------------------"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START - $DHCP_END"
echo "  SSID           : $SSID"
echo "  Country / Ch   : $COUNTRY_CODE / $CHANNEL"
echo "  Use Unbound    : $USE_UNBOUND"
echo "------------------------------------------------------------"
read -r -p "Proceed with full automated installation? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || { echo "Aborted."; exit 1; }
echo
