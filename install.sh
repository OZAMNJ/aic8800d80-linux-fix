#!/usr/bin/env bash
# AIC8800D80 Linux Fix — Fully Interactive Installer v3
# https://github.com/OZAMNJ/aic8800d80-linux-fix
#
# Run as: sudo bash install.sh
#
# Copyright (C) 2025 OZAMNJ
# SPDX-License-Identifier: MIT

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────
REPO_API="https://api.github.com/repos/radxa-pkg/aic8800/releases/latest"
RADXA_REPO="https://github.com/radxa-pkg/aic8800"
QUIRK="usb-storage.quirks=1111:1111:i"      # AIC8800D80 CD-ROM mode VID:PID
CMDLINE_FILE="/boot/firmware/cmdline.txt"
BACKUP_DIR="/var/backups/aic8800d80-install-$(date +%Y%m%d%H%M%S)"
VERSION="3.0.0"

# ─────────────────────────────────────────────────────────────────────
# Root check
# ─────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  echo "Use: sudo bash install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────
info()  { echo "  [INFO] $*"; }
ok()    { echo "  [ OK ] $*"; }
warn()  { echo "  [WARN] $*"; }
die()   { echo "  [ERR ] $*" >&2; exit 1; }
step()  { echo; echo "──────────────────────────────────────────"; echo "  $*"; echo "──────────────────────────────────────────"; }

# ─────────────────────────────────────────────────────────────────────
# Input helpers
# ─────────────────────────────────────────────────────────────────────
prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "  $prompt [$default]: " value
  echo "${value:-$default}"
}

prompt_secret_default() {
  local prompt="$1" default="$2" value
  read -r -s -p "  $prompt [default hidden]: " value
  echo
  echo "${value:-$default}"
}

# ─────────────────────────────────────────────────────────────────────
# Validation helpers
# ─────────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Missing required repo file: $f — are you running from the cloned repo directory?"
}

iface_exists() {
  ip link show "$1" >/dev/null 2>&1
}

list_ifaces() {
  ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

validate_ip() {
  local ip="$1"
  local re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  [[ "$ip" =~ $re ]] || return 1
  local IFS='.'
  read -ra octets <<< "$ip"
  for o in "${octets[@]}"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]+)$ ]] && (( cidr >= 1 && cidr <= 30 ))
}

validate_ip_in_subnet() {
  # Check that IP is in subnet gateway/cidr using bash integer math
  local ip="$1" gw="$2" cidr="$3"
  local ip_int gw_int mask
  IFS='.' read -r a b c d <<< "$ip"
  ip_int=$(( (a<<24) | (b<<16) | (c<<8) | d ))
  IFS='.' read -r a b c d <<< "$gw"
  gw_int=$(( (a<<24) | (b<<16) | (c<<8) | d ))
  mask=$(( 0xFFFFFFFF << (32 - cidr) & 0xFFFFFFFF ))
  (( (ip_int & mask) == (gw_int & mask) ))
}

validate_wpa_passphrase() {
  local p="$1"
  local len=${#p}
  (( len >= 8 && len <= 63 )) || return 1
}

same_subnet_24() {
  local ip1="$1" ip2="$2"
  [[ "${ip1%.*}" == "${ip2%.*}" ]]
}

validate_channel() {
  local ch="$1"
  [[ "$ch" =~ ^(1|2|3|4|5|6|7|8|9|10|11|12|13|36|40|44|48|52|56|60|64|100|104|108|112|116|120|124|128|132|136|140|149|153|157|161|165)$ ]]
}

validate_country_code() {
  local cc="$1"
  [[ "$cc" =~ ^[A-Z]{2}$ ]]
}

verify_deb_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Downloaded file not found: $f"
  dpkg --info "$f" >/dev/null 2>&1 || die "File does not appear to be a valid Debian package: $f"
  ok "Package verified: $(basename "$f")"
}

# ─────────────────────────────────────────────────────────────────────
# Connectivity helpers
# ─────────────────────────────────────────────────────────────────────
internet_ok() {
  ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && return 0
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && return 0
  curl -fsI --connect-timeout 5 https://github.com >/dev/null 2>&1 && return 0
  wget -q --spider --timeout=5 https://github.com >/dev/null 2>&1 && return 0
  return 1
}

download_file() {
  local url="$1" out="$2"
  info "Downloading: $(basename "$out")"
  if command_exists wget; then
    wget -q --show-progress -O "$out" "$url" || die "Download failed: $url"
  elif command_exists curl; then
    curl -L --progress-bar -o "$out" "$url" || die "Download failed: $url"
  else
    die "Neither wget nor curl is available"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Dynamic version resolution
# ─────────────────────────────────────────────────────────────────────
resolve_aic_version() {
  info "Fetching latest AIC8800 release from GitHub API..."
  local latest_json latest_tag

  if command_exists curl; then
    latest_json="$(curl -fsL --connect-timeout 10 "$REPO_API" 2>/dev/null)" || latest_json=""
  elif command_exists wget; then
    latest_json="$(wget -qO- --timeout=10 "$REPO_API" 2>/dev/null)" || latest_json=""
  fi

  if [[ -n "$latest_json" ]]; then
    latest_tag="$(echo "$latest_json" | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    if [[ -n "$latest_tag" ]]; then
      # tag is like "4.0+git20250410.b99ca8b6-3"
      AIC_VER="$latest_tag"
      # URL-encode the + sign for the download URL
      local encoded_tag
      encoded_tag="$(echo "$latest_tag" | sed 's/+/%2B/g')"
      BASE_URL="${RADXA_REPO}/releases/download/${encoded_tag}"
      ok "Resolved latest AIC8800 version: $AIC_VER"
      return 0
    fi
  fi

  warn "Could not resolve latest version from GitHub API. Falling back to pinned version."
  AIC_VER="4.0+git20250410.b99ca8b6-3"
  BASE_URL="${RADXA_REPO}/releases/download/4.0%2Bgit20250410.b99ca8b6-3"
}

# ─────────────────────────────────────────────────────────────────────
# Backup helper (used before modifying files)
# ─────────────────────────────────────────────────────────────────────
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local dest="${BACKUP_DIR}$(dirname "$f")"
  mkdir -p "$dest"
  cp "$f" "$dest/"
  info "Backed up: $f → $BACKUP_DIR$(dirname "$f")/$(basename "$f")"
}

# ─────────────────────────────────────────────────────────────────────
# cmdline.txt quirk
# ─────────────────────────────────────────────────────────────────────
append_cmdline_quirk() {
  if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found. Add this manually after install:"
    warn "  $QUIRK"
    return 0
  fi

  if grep -q "$QUIRK" "$CMDLINE_FILE"; then
    ok "cmdline.txt already contains $QUIRK"
    return 0
  fi

  info "Adding usb-storage quirk to $CMDLINE_FILE"
  backup_file "$CMDLINE_FILE"
  local current
  current="$(tr -d '\n' < "$CMDLINE_FILE" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  printf '%s %s\n' "$current" "$QUIRK" > "$CMDLINE_FILE"
  ok "cmdline.txt updated (backup saved to $BACKUP_DIR)"
}

# ─────────────────────────────────────────────────────────────────────
# IP forwarding
# ─────────────────────────────────────────────────────────────────────
enable_ip_forwarding() {
  info "Enabling IPv4 forwarding"
  backup_file "/etc/sysctl.conf"
  if grep -q '^#net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  elif ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  ok "IPv4 forwarding enabled"
}

# ─────────────────────────────────────────────────────────────────────
# NAT rules
# ─────────────────────────────────────────────────────────────────────
install_nat_rules() {
  local wan="$1" lan="$2"

  info "Applying NAT rules (iptables)"
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
    info "Rules written to /etc/iptables/rules.v4"
  }

  ok "NAT rules installed and persisted"
}

# ─────────────────────────────────────────────────────────────────────
# hostapd.conf validation
# ─────────────────────────────────────────────────────────────────────
validate_hostapd_conf() {
  local conf="$1"
  grep -q '^interface=' "$conf" || die "hostapd.conf missing interface="
  grep -q '^ssid=' "$conf" || die "hostapd.conf missing ssid="
  grep -q '^wpa_passphrase=' "$conf" || die "hostapd.conf missing wpa_passphrase="
  grep -q '^country_code=' "$conf" || die "hostapd.conf missing country_code="
  ok "hostapd.conf validated"
}

# ─────────────────────────────────────────────────────────────────────
# Post-install driver verification
# ─────────────────────────────────────────────────────────────────────
verify_driver_post_install() {
  info "Verifying DKMS build status"
  if dkms status 2>/dev/null | grep -q "aic8800-usb.*installed"; then
    ok "aic8800-usb DKMS: installed"
  elif dkms status 2>/dev/null | grep -q "aic8800-usb.*built"; then
    ok "aic8800-usb DKMS: built (will be active after reboot)"
  else
    warn "aic8800-usb DKMS status unclear — check with: dkms status"
  fi

  info "Verifying firmware files"
  if ls /lib/firmware/aic8800D80/ >/dev/null 2>&1; then
    ok "Firmware files present in /lib/firmware/aic8800D80/"
  else
    warn "Firmware directory /lib/firmware/aic8800D80/ not found"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     AIC8800D80 Linux Fix — Fully Interactive Installer       ║"
echo "║     v${VERSION}   https://github.com/OZAMNJ/aic8800d80-linux-fix  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
echo "  IMPORTANT: Connect your Raspberry Pi to wired LAN/Ethernet"
echo "  BEFORE running this installer. Active internet is required to"
echo "  install packages and download firmware/DKMS from GitHub."
echo

# ─────────────────────────────────────────────────────────────────────
# Internet check
# ─────────────────────────────────────────────────────────────────────
info "Checking internet connectivity..."
internet_ok || die "No internet connection detected. Connect LAN/Ethernet and retry."
ok "Internet connection confirmed"

# ─────────────────────────────────────────────────────────────────────
# Architecture check
# ─────────────────────────────────────────────────────────────────────
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
  warn "Unexpected architecture: $ARCH — this guide targets arm64/armv7l (Raspberry Pi OS)"
  read -r -p "  Continue anyway? (yes/no) [no]: " arch_ok
  [[ "${arch_ok:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"
fi

# ─────────────────────────────────────────────────────────────────────
# Resolve latest package version dynamically
# ─────────────────────────────────────────────────────────────────────
step "Resolving AIC8800 package version"
resolve_aic_version
FW_DEB="aic8800-firmware_${AIC_VER}_all.deb"
DKMS_DEB="aic8800-usb-dkms_${AIC_VER}_all.deb"

# ─────────────────────────────────────────────────────────────────────
# Interface listing
# ─────────────────────────────────────────────────────────────────────
step "Network interface detection"
info "Detected interfaces:"
list_ifaces | sed 's/^/    /'
echo

# ─────────────────────────────────────────────────────────────────────
# Interactive prompts with validation
# ─────────────────────────────────────────────────────────────────────
step "Configuration prompts"

# WAN interface
while true; do
  WAN_IFACE="$(prompt_default "WAN/uplink interface (has internet)" "eth0")"
  if iface_exists "$WAN_IFACE"; then
    ok "WAN interface '$WAN_IFACE' found"
    break
  else
    warn "Interface '$WAN_IFACE' not found. Available: $(list_ifaces | tr '\n' ' ')"
    read -r -p "  Try again? (yes/no) [yes]: " retry
    [[ "${retry:-yes}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"
  fi
done

# LAN/AP interface
while true; do
  LAN_IFACE="$(prompt_default "LAN/AP WiFi interface (AIC8800D80 will become this)" "wlan0")"
  if [[ "$LAN_IFACE" == "$WAN_IFACE" ]]; then
    warn "LAN and WAN interface cannot be the same"
    continue
  fi
  if ! iface_exists "$LAN_IFACE"; then
    warn "Interface '$LAN_IFACE' not yet visible (the AIC8800D80 driver may not be active yet — this is normal before reboot)"
  else
    ok "LAN/AP interface '$LAN_IFACE' found"
  fi
  break
done

# AP gateway IP
while true; do
  AP_IP="$(prompt_default "AP gateway IP" "192.168.73.1")"
  if validate_ip "$AP_IP"; then
    ok "AP gateway IP: $AP_IP"
    break
  else
    warn "'$AP_IP' is not a valid IP address"
  fi
done

# CIDR
while true; do
  AP_CIDR="$(prompt_default "AP subnet CIDR bits" "24")"
  if validate_cidr "$AP_CIDR"; then
    ok "CIDR: /$AP_CIDR"
    break
  else
    warn "CIDR must be 1–30"
  fi
done

# DHCP range
while true; do
  DHCP_START="$(prompt_default "DHCP start IP" "192.168.73.10")"
  if ! validate_ip "$DHCP_START"; then
    warn "'$DHCP_START' is not a valid IP"; continue
  fi
  if ! validate_ip_in_subnet "$DHCP_START" "$AP_IP" "$AP_CIDR"; then
    warn "$DHCP_START is not inside $AP_IP/$AP_CIDR subnet"; continue
  fi
  ok "DHCP start: $DHCP_START"; break
done

while true; do
  DHCP_END="$(prompt_default "DHCP end IP" "192.168.73.100")"
  if ! validate_ip "$DHCP_END"; then
    warn "'$DHCP_END' is not a valid IP"; continue
  fi
  if ! validate_ip_in_subnet "$DHCP_END" "$AP_IP" "$AP_CIDR"; then
    warn "$DHCP_END is not inside $AP_IP/$AP_CIDR subnet"; continue
  fi
  ok "DHCP end: $DHCP_END"; break
done

NETMASK="$(prompt_default "DHCP netmask" "255.255.255.0")"
LEASE_TIME="$(prompt_default "DHCP lease time" "24h")"

# SSID
SSID="$(prompt_default "WiFi SSID" "TravelRouter")"
[[ -n "$SSID" ]] || die "SSID cannot be empty"

# Password
while true; do
  WPA_PSK="$(prompt_secret_default "WiFi password (8–63 chars)" "ChangeMe123")"
  if validate_wpa_passphrase "$WPA_PSK"; then
    ok "Password length OK"
    break
  else
    warn "Password must be 8–63 characters"
  fi
done

# Country code
while true; do
  COUNTRY_CODE="$(prompt_default "WiFi country code (ISO 3166-1 alpha-2, e.g. DE)" "DE")"
  COUNTRY_CODE="${COUNTRY_CODE^^}"
  if validate_country_code "$COUNTRY_CODE"; then
    ok "Country code: $COUNTRY_CODE"
    break
  else
    warn "Country code must be exactly 2 uppercase letters (e.g. DE, US, GB)"
  fi
done

# Channel
while true; do
  CHANNEL="$(prompt_default "WiFi channel (2.4GHz: 1/6/11  5GHz: 36/40/44/48)" "6")"
  if validate_channel "$CHANNEL"; then
    ok "Channel: $CHANNEL"
    break
  else
    warn "Invalid channel. Common 2.4GHz: 1,6,11 — Common 5GHz: 36,40,44,48"
  fi
done

USE_UNBOUND="$(prompt_default "Use Unbound/system DNS on port 53? (yes/no)" "yes")"
PROTECT_SSH="$(prompt_default "Add SSH protection rule on WAN interface? (yes/no)" "yes")"

# WAN overlap check
CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  warn "WAN IP $CURRENT_WAN_IP may overlap with AP subnet based on $AP_IP"
  warn "Consider changing AP gateway to a different /24 subnet"
fi

# ─────────────────────────────────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────────────────────────────────
step "Confirm settings"
echo "  WAN interface  : $WAN_IFACE"
echo "  LAN/AP iface   : $LAN_IFACE"
echo "  AP gateway     : $AP_IP/$AP_CIDR"
echo "  DHCP range     : $DHCP_START – $DHCP_END"
echo "  SSID           : $SSID"
echo "  Country code   : $COUNTRY_CODE"
echo "  Channel        : $CHANNEL"
echo "  Use Unbound    : $USE_UNBOUND"
echo "  Protect SSH    : $PROTECT_SSH"
echo "  AIC8800 ver    : $AIC_VER"
echo
read -r -p "  Continue with these settings? (yes/no) [yes]: " CONFIRM
CONFIRM="${CONFIRM:-yes}"
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"

# ─────────────────────────────────────────────────────────────────────
# Preflight: check repo files are present
# ─────────────────────────────────────────────────────────────────────
require_file "$SCRIPT_DIR/etc/modprobe.d/aic8800-blacklist.conf"
require_file "$SCRIPT_DIR/etc/udev/rules.d/99-aic8800-switch.rules"
require_file "$SCRIPT_DIR/etc/systemd/system/aic8800-switch.service"
require_file "$SCRIPT_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf"
require_file "$SCRIPT_DIR/etc/hostapd/hostapd.conf"
require_file "$SCRIPT_DIR/etc/default/hostapd"
require_file "$SCRIPT_DIR/etc/dnsmasq.d/travel-ap.conf"
require_file "$SCRIPT_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf"

mkdir -p "$BACKUP_DIR"
info "Backups will be saved to: $BACKUP_DIR"

# ─────────────────────────────────────────────────────────────────────
# STEP 1: Install packages
# ─────────────────────────────────────────────────────────────────────
step "[1/8] Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  dkms \
  "linux-headers-$(uname -r)" \
  usb-modeswitch \
  hostapd \
  dnsmasq \
  wget \
  curl \
  ca-certificates \
  iproute2 \
  iptables \
  iptables-persistent \
  netfilter-persistent
ok "Prerequisites installed"

# ─────────────────────────────────────────────────────────────────────
# STEP 2: SSH protection
# ─────────────────────────────────────────────────────────────────────
step "[2/8] SSH protection"
if [[ "$PROTECT_SSH" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  info "Installing SSH protection rule on $WAN_IFACE"
  iptables -C INPUT -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT

  iptables -C INPUT -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

  netfilter-persistent save >/dev/null 2>&1 || true
  ok "SSH protection installed on $WAN_IFACE"
else
  info "Skipping SSH protection rule"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 3: Download + verify + install AIC8800 driver
# ─────────────────────────────────────────────────────────────────────
step "[3/8] Downloading and installing AIC8800 firmware + DKMS"

rm -f "/tmp/${FW_DEB}" "/tmp/${DKMS_DEB}"
download_file "${BASE_URL}/${FW_DEB}" "/tmp/${FW_DEB}"
download_file "${BASE_URL}/${DKMS_DEB}" "/tmp/${DKMS_DEB}"

verify_deb_file "/tmp/${FW_DEB}"
verify_deb_file "/tmp/${DKMS_DEB}"

info "Removing any stale firmware from previous installs"
rm -rf /lib/firmware/aic8800D80

info "Installing firmware package"
dpkg -i "/tmp/${FW_DEB}"

info "Installing DKMS package (will compile kernel module)"
dpkg -i "/tmp/${DKMS_DEB}" || {
  warn "dpkg returned non-zero, attempting apt-get -f install to fix dependencies"
  apt-get -f install -y
  dpkg -i "/tmp/${DKMS_DEB}"
}

verify_driver_post_install

# ─────────────────────────────────────────────────────────────────────
# STEP 4: Prepare customized config files
# ─────────────────────────────────────────────────────────────────────
step "[4/8] Preparing customized configs"
TMP_DIR="$(mktemp -d)"
export TMP_DIR
trap 'rm -rf "$TMP_DIR"' EXIT

cp -a "$SCRIPT_DIR/etc" "$TMP_DIR/"

# Backup before modifying
backup_file "/etc/hostapd/hostapd.conf"
backup_file "/etc/dnsmasq.d/travel-ap.conf"
backup_file "/etc/NetworkManager/conf.d/99-aic-ap.conf"
backup_file "/etc/systemd/system/aic8800-switch.service"
backup_file "/etc/default/hostapd"

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

# Upstream DNS (Unbound disabled)
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

# ─────────────────────────────────────────────────────────────────────
# STEP 5: Copy configs to system
# ─────────────────────────────────────────────────────────────────────
step "[5/8] Installing config files to system"

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

ok "Config files installed"

# ─────────────────────────────────────────────────────────────────────
# STEP 6: Validate + configure system
# ─────────────────────────────────────────────────────────────────────
step "[6/8] Validating + configuring system"
validate_hostapd_conf /etc/hostapd/hostapd.conf
append_cmdline_quirk
enable_ip_forwarding
install_nat_rules "$WAN_IFACE" "$LAN_IFACE"
ok "System configuration complete"

# ─────────────────────────────────────────────────────────────────────
# STEP 7: Enable services
# ─────────────────────────────────────────────────────────────────────
step "[7/8] Enabling services"
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
systemctl enable aic8800-switch hostapd dnsmasq
ok "Services enabled"

# ─────────────────────────────────────────────────────────────────────
# STEP 8: Summary
# ─────────────────────────────────────────────────────────────────────
step "[8/8] Installation complete"
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                 Installation complete!                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-20s  %-37s ║\n" "WAN interface"  "$WAN_IFACE"
printf "║  %-20s  %-37s ║\n" "LAN/AP iface"   "$LAN_IFACE"
printf "║  %-20s  %-37s ║\n" "AP gateway"     "$AP_IP/$AP_CIDR"
printf "║  %-20s  %-37s ║\n" "DHCP range"     "$DHCP_START – $DHCP_END"
printf "║  %-20s  %-37s ║\n" "SSID"           "$SSID"
printf "║  %-20s  %-37s ║\n" "Country/Channel" "$COUNTRY_CODE / ch$CHANNEL"
printf "║  %-20s  %-37s ║\n" "AIC8800 version" "$AIC_VER"
printf "║  %-20s  %-37s ║\n" "Backups saved"  "$BACKUP_DIR"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Next: reboot                                                ║"
echo "║    sudo reboot                                               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  After reboot, verify:                                       ║"
echo "║    lsusb | grep a69c          (expect a69c:8d81)             ║"
echo "║    ip addr show $LAN_IFACE"
printf  "║    %-58s ║\n" "systemctl status aic8800-switch hostapd dnsmasq"
echo "║    dkms status                (expect aic8800-usb installed) ║"
echo "║    ping -c3 8.8.8.8           (from WiFi client)             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
