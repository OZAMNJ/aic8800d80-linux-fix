#!/usr/bin/env bash
# AIC8800D80 Linux Fix — Fully Interactive Installer v3.2
# https://github.com/OZAMNJ/aic8800d80-linux-fix
#
# Run as: sudo bash install.sh
# Options:
#   --dry-run          Show what would be done without making any changes
#   --non-interactive  Use all defaults (no prompts) — set env vars to override
#
# Copyright (C) 2025 OZAMNJ
# SPDX-License-Identifier: MIT

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Parse flags
# ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
NON_INTERACTIVE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=true ;;
    --non-interactive)    NON_INTERACTIVE=true ;;
    --help|-h)
      echo "Usage: sudo bash install.sh [--dry-run] [--non-interactive]"
      echo ""
      echo "  --dry-run          Show all steps without making any changes"
      echo "  --non-interactive  Use defaults; override with env vars:"
      echo "    WAN_IFACE, LAN_IFACE, AP_IP, AP_CIDR, DHCP_START, DHCP_END"
      echo "    NETMASK, LEASE_TIME, SSID, WPA_PSK, COUNTRY_CODE, CHANNEL"
      echo "    USE_UNBOUND, PROTECT_SSH"
      exit 0
      ;;
    *) echo "Unknown option: $arg (use --help for usage)"; exit 1 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────
REPO_API="https://api.github.com/repos/radxa-pkg/aic8800/releases/latest"
RADXA_REPO="https://github.com/radxa-pkg/aic8800"
QUIRK="usb-storage.quirks=1111:1111:i"
CMDLINE_FILE="/boot/firmware/cmdline.txt"
BACKUP_DIR="/var/backups/aic8800d80-install-$(date +%Y%m%d%H%M%S)"
VERSION="3.2.1"

# ─────────────────────────────────────────────────────────────────────
# Root check (skip in dry-run)
# ─────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]] && [[ "$DRY_RUN" == false ]]; then
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
dryrun(){ echo "  [DRY ] WOULD: $*"; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "$*"
  else
    eval "$*"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Input helpers
# ─────────────────────────────────────────────────────────────────────
prompt_default() {
  local prompt="$1" default="$2" value
  if [[ "$NON_INTERACTIVE" == true ]]; then echo "$default"; return; fi
  read -r -p "  $prompt [$default]: " value
  echo "${value:-$default}"
}

prompt_secret_default() {
  local prompt="$1" default="$2" value
  if [[ "$NON_INTERACTIVE" == true ]]; then echo "$default"; return; fi
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
  [[ -f "$f" ]] || die "Missing required repo file: $f — run from the cloned repo directory"
}

iface_exists() { ip link show "$1" >/dev/null 2>&1; }

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
  dpkg --info "$f" >/dev/null 2>&1 || die "Not a valid Debian package: $f"
  ok "Package verified: $(basename "$f")"
}

# Escape a string for safe use as sed replacement (handles / & \ )
sed_escape() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
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
  if [[ "$DRY_RUN" == true ]]; then dryrun "wget/curl $url → $out"; return 0; fi
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
    # Check for API rate limit
    if echo "$latest_json" | grep -q '"rate limit"\|"API rate limit"\|"403"'; then
      warn "GitHub API rate limit hit — falling back to pinned version"
    else
      latest_tag="$(echo "$latest_json" | grep '"tag_name"' | head -n1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
      if [[ -n "$latest_tag" ]]; then
        AIC_VER="$latest_tag"
        local encoded_tag
        encoded_tag="$(echo "$latest_tag" | sed 's/+/%2B/g')"
        BASE_URL="${RADXA_REPO}/releases/download/${encoded_tag}"
        ok "Resolved latest AIC8800 version: $AIC_VER"
        return 0
      else
        warn "GitHub API returned JSON but no tag_name found — response: $(echo "$latest_json" | head -c 120)"
      fi
    fi
  else
    warn "GitHub API request failed (no response) — check internet connectivity"
  fi

  warn "Falling back to pinned version: 4.0+git20250410.b99ca8b6-3"
  AIC_VER="4.0+git20250410.b99ca8b6-3"
  BASE_URL="${RADXA_REPO}/releases/download/4.0%2Bgit20250410.b99ca8b6-3"
}

# ─────────────────────────────────────────────────────────────────────
# Backup helper
# ─────────────────────────────────────────────────────────────────────
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "cp $f → $BACKUP_DIR$(dirname "$f")/$(basename "$f")"
    return 0
  fi
  local dest="${BACKUP_DIR}$(dirname "$f")"
  mkdir -p "$dest"
  cp "$f" "$dest/"
  info "Backed up: $f → $dest/$(basename "$f")"
}

# ─────────────────────────────────────────────────────────────────────
# Apply {{PLACEHOLDER}} replacements to a template file
# Usage: apply_template <file> KEY1 VAL1 KEY2 VAL2 ...
# ─────────────────────────────────────────────────────────────────────
apply_template() {
  local file="$1"; shift
  local sed_args=()
  while (( $# >= 2 )); do
    local key="$1" val
    val="$(sed_escape "$2")"
    sed_args+=(-e "s|{{${key}}}|${val}|g")
    shift 2
  done
  sed -i "${sed_args[@]}" "$file"
  # Warn on any unreplaced placeholders
  local remaining
  remaining="$(grep -oP '\{\{[^}]+\}\}' "$file" | sort -u || true)"
  if [[ -n "$remaining" ]]; then
    warn "Unreplaced placeholders in $(basename "$file"): $remaining"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# cmdline.txt quirk
# ─────────────────────────────────────────────────────────────────────
append_cmdline_quirk() {
  if [[ ! -f "$CMDLINE_FILE" ]]; then
    warn "$CMDLINE_FILE not found. Add manually: $QUIRK"
    return 0
  fi
  if grep -q "$QUIRK" "$CMDLINE_FILE"; then
    ok "cmdline.txt already contains $QUIRK"; return 0
  fi
  info "Adding usb-storage quirk to $CMDLINE_FILE"
  backup_file "$CMDLINE_FILE"
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  local current
  current="$(tr -d '\n' < "$CMDLINE_FILE" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  printf '%s %s\n' "$current" "$QUIRK" > "$CMDLINE_FILE"
  ok "cmdline.txt updated (backup saved to $BACKUP_DIR)"
}

# ─────────────────────────────────────────────────────────────────────
# IP forwarding
# ─────────────────────────────────────────────────────────────────────
enable_ip_forwarding() {
  info "Enabling IPv4 forwarding"
  backup_file "/etc/sysctl.conf"
  if [[ "$DRY_RUN" == true ]]; then dryrun "sysctl net.ipv4.ip_forward=1"; return 0; fi
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
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "iptables -t nat -A POSTROUTING -o $wan -j MASQUERADE"
    dryrun "iptables -A FORWARD -i $lan -o $wan -j ACCEPT"
    dryrun "netfilter-persistent save"
    return 0
  fi
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
  grep -q '^interface=' "$conf"     || die "hostapd.conf missing interface="
  grep -q '^ssid=' "$conf"          || die "hostapd.conf missing ssid="
  grep -q '^wpa_passphrase=' "$conf"|| die "hostapd.conf missing wpa_passphrase="
  grep -q '^country_code=' "$conf"  || die "hostapd.conf missing country_code="
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
    ok "aic8800-usb DKMS: built (active after reboot)"
  else
    warn "aic8800-usb DKMS status unclear — check with: dkms status"
  fi
  info "Verifying firmware files"
  if ls /lib/firmware/aic8800D80/ >/dev/null 2>&1; then
    ok "Firmware present: /lib/firmware/aic8800D80/"
  else
    warn "Firmware directory /lib/firmware/aic8800D80/ not found"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AIC8800D80 Linux Fix — Fully Interactive Installer         ║"
echo "║   v${VERSION}  https://github.com/OZAMNJ/aic8800d80-linux-fix    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
[[ "$DRY_RUN" == true ]] && warn "DRY-RUN MODE — no changes will be made to your system"
[[ "$NON_INTERACTIVE" == true ]] && info "NON-INTERACTIVE MODE — using defaults / env vars"
echo
echo "  IMPORTANT: Connect Raspberry Pi to wired LAN/Ethernet BEFORE"
echo "  running this installer. Active internet is required."
echo

# ─────────────────────────────────────────────────────────────────────
# Internet + architecture check
# ─────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == false ]]; then
  info "Checking internet connectivity..."
  internet_ok || die "No internet connection. Connect LAN/Ethernet and retry."
  ok "Internet connection confirmed"
else
  dryrun "Check internet connectivity"
fi

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "armv7l" ]]; then
  warn "Unexpected architecture: $ARCH — targets arm64/armv7l (Raspberry Pi OS)"
  if [[ "$NON_INTERACTIVE" == false ]]; then
    read -r -p "  Continue anyway? (yes/no) [no]: " arch_ok
    [[ "${arch_ok:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# Resolve version dynamically
# ─────────────────────────────────────────────────────────────────────
step "Resolving AIC8800 package version"
resolve_aic_version
FW_DEB="aic8800-firmware_${AIC_VER}_all.deb"

# Check if this version is already installed
if [[ "$DRY_RUN" == false ]]; then
  INSTALLED_VER="$(dpkg-query -W -f='${Version}' aic8800-usb-dkms 2>/dev/null || true)"
  if [[ -n "$INSTALLED_VER" ]]; then
    if [[ "$INSTALLED_VER" == "$AIC_VER" ]]; then
      ok "aic8800-usb-dkms $AIC_VER is already installed"
      if [[ "$NON_INTERACTIVE" == false ]]; then
        read -r -p "  Re-install anyway? (yes/no) [no]: " reinstall
        [[ "${reinstall:-no}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || {
          info "Skipping driver download/install (already up to date)"
          SKIP_DRIVER=true
        }
      fi
    else
      info "Upgrading aic8800-usb-dkms: $INSTALLED_VER → $AIC_VER"
    fi
  fi
fi
SKIP_DRIVER="${SKIP_DRIVER:-false}"
DKMS_DEB="aic8800-usb-dkms_${AIC_VER}_all.deb"

# ─────────────────────────────────────────────────────────────────────
# Interface detection
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
  WAN_IFACE="${WAN_IFACE:-$(prompt_default "WAN/uplink interface (has internet)" "eth0")}"
  if iface_exists "$WAN_IFACE"; then
    ok "WAN interface '$WAN_IFACE' found"; break
  elif [[ "$DRY_RUN" == true ]]; then
    warn "Dry-run: skipping interface check for $WAN_IFACE"; break
  else
    warn "Interface '$WAN_IFACE' not found. Available: $(list_ifaces | tr '\n' ' ')"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "WAN interface '$WAN_IFACE' not found"; fi
    unset WAN_IFACE
    read -r -p "  Try again? (yes/no) [yes]: " retry
    [[ "${retry:-yes}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"
  fi
done

# LAN/AP interface
while true; do
  LAN_IFACE="${LAN_IFACE:-$(prompt_default "LAN/AP WiFi interface (AIC8800D80)" "wlan0")}"
  if [[ "$LAN_IFACE" == "$WAN_IFACE" ]]; then
    warn "LAN and WAN cannot be the same interface"; unset LAN_IFACE; continue
  fi
  if ! iface_exists "$LAN_IFACE"; then
    warn "Interface '$LAN_IFACE' not yet visible (normal before driver is active)"
  else
    ok "LAN/AP interface '$LAN_IFACE' found"
  fi
  break
done

# AP gateway IP
while true; do
  AP_IP="${AP_IP:-$(prompt_default "AP gateway IP" "192.168.73.1")}"
  if validate_ip "$AP_IP"; then ok "AP gateway IP: $AP_IP"; break
  else
    warn "'$AP_IP' is not a valid IP address"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid AP_IP: $AP_IP"; fi
    unset AP_IP
  fi
done

# CIDR
while true; do
  AP_CIDR="${AP_CIDR:-$(prompt_default "AP subnet CIDR bits" "24")}"
  if validate_cidr "$AP_CIDR"; then ok "CIDR: /$AP_CIDR"; break
  else
    warn "CIDR must be 1–30"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid AP_CIDR: $AP_CIDR"; fi
    unset AP_CIDR
  fi
done

# DHCP start
while true; do
  DHCP_START="${DHCP_START:-$(prompt_default "DHCP start IP" "192.168.73.10")}"
  if ! validate_ip "$DHCP_START"; then
    warn "'$DHCP_START' is not a valid IP"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid DHCP_START"; fi
    unset DHCP_START; continue
  fi
  if ! validate_ip_in_subnet "$DHCP_START" "$AP_IP" "$AP_CIDR"; then
    warn "$DHCP_START is not inside $AP_IP/$AP_CIDR"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "DHCP_START out of subnet"; fi
    unset DHCP_START; continue
  fi
  ok "DHCP start: $DHCP_START"; break
done

# DHCP end
while true; do
  DHCP_END="${DHCP_END:-$(prompt_default "DHCP end IP" "192.168.73.100")}"
  if ! validate_ip "$DHCP_END"; then
    warn "'$DHCP_END' is not a valid IP"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid DHCP_END"; fi
    unset DHCP_END; continue
  fi
  if ! validate_ip_in_subnet "$DHCP_END" "$AP_IP" "$AP_CIDR"; then
    warn "$DHCP_END is not inside $AP_IP/$AP_CIDR"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "DHCP_END out of subnet"; fi
    unset DHCP_END; continue
  fi
  ok "DHCP end: $DHCP_END"; break
done

NETMASK="${NETMASK:-$(prompt_default "DHCP netmask" "255.255.255.0")}"
LEASE_TIME="${LEASE_TIME:-$(prompt_default "DHCP lease time" "24h")}"
SSID="${SSID:-$(prompt_default "WiFi SSID" "TravelRouter")}"
[[ -n "$SSID" ]] || die "SSID cannot be empty"

# Password
while true; do
  WPA_PSK="${WPA_PSK:-$(prompt_secret_default "WiFi password (8–63 chars)" "ChangeMe123")}"
  if validate_wpa_passphrase "$WPA_PSK"; then ok "Password length OK"; break
  else
    warn "Password must be 8–63 characters"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid WPA_PSK length"; fi
    unset WPA_PSK
  fi
done

# Country code
while true; do
  COUNTRY_CODE="${COUNTRY_CODE:-$(prompt_default "WiFi country code (e.g. DE, US, GB)" "DE")}"
  COUNTRY_CODE="${COUNTRY_CODE^^}"
  if validate_country_code "$COUNTRY_CODE"; then ok "Country code: $COUNTRY_CODE"; break
  else
    warn "Must be 2 uppercase letters (e.g. DE, US, GB)"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid COUNTRY_CODE"; fi
    unset COUNTRY_CODE
  fi
done

# Channel
while true; do
  CHANNEL="${CHANNEL:-$(prompt_default "WiFi channel (2.4GHz: 1/6/11  5GHz: 36/40/44/48)" "6")}"
  if validate_channel "$CHANNEL"; then ok "Channel: $CHANNEL"; break
  else
    warn "Invalid channel. Common 2.4GHz: 1,6,11 — Common 5GHz: 36,40,44,48"
    if [[ "$NON_INTERACTIVE" == true ]]; then die "Invalid CHANNEL"; fi
    unset CHANNEL
  fi
done

USE_UNBOUND="${USE_UNBOUND:-$(prompt_default "Use Unbound/system DNS on port 53? (yes/no)" "yes")}"
PROTECT_SSH="${PROTECT_SSH:-$(prompt_default "Add SSH protection rule on WAN? (yes/no)" "yes")}"

# WAN overlap warning
CURRENT_WAN_IP="$(ip -4 addr show "$WAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1 || true)"
if [[ -n "$CURRENT_WAN_IP" ]] && same_subnet_24 "$CURRENT_WAN_IP" "$AP_IP"; then
  warn "WAN IP $CURRENT_WAN_IP may overlap with AP subnet $AP_IP — consider using a different /24"
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
echo "  Dry-run mode   : $DRY_RUN"
echo

if [[ "$NON_INTERACTIVE" == false && "$DRY_RUN" == false ]]; then
  read -r -p "  Continue with these settings? (yes/no) [yes]: " CONFIRM
  [[ "${CONFIRM:-yes}" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || die "Aborted"
fi

# ─────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == false ]]; then
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
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 1: Install packages
# ─────────────────────────────────────────────────────────────────────
step "[1/8] Installing prerequisites"
if [[ "$DRY_RUN" == true ]]; then
  dryrun "apt-get install dkms linux-headers-$(uname -r) usb-modeswitch hostapd dnsmasq wget curl ca-certificates iproute2 iptables iptables-persistent netfilter-persistent"
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    dkms "linux-headers-$(uname -r)" \
    usb-modeswitch hostapd dnsmasq \
    wget curl ca-certificates iproute2 \
    iptables iptables-persistent netfilter-persistent
  ok "Prerequisites installed"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 2: SSH protection
# ─────────────────────────────────────────────────────────────────────
step "[2/8] SSH protection"
if [[ "$PROTECT_SSH" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    dryrun "iptables -I INPUT 1 -i $WAN_IFACE -p tcp --dport 22 -j ACCEPT"
  else
    info "Installing SSH protection rule on $WAN_IFACE"
    iptables -C INPUT -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -i "$WAN_IFACE" -p tcp --dport 22 -j ACCEPT
    iptables -C INPUT -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 2 -i "$WAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT
    netfilter-persistent save >/dev/null 2>&1 || true
    ok "SSH protection installed"
  fi
else
  info "Skipping SSH protection rule"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 3: Download + verify + install AIC8800 driver
# ─────────────────────────────────────────────────────────────────────
step "[3/8] Downloading and installing AIC8800 firmware + DKMS"
if [[ "$SKIP_DRIVER" == true ]]; then
  ok "Skipping — aic8800-usb-dkms $AIC_VER already installed"
else
rm -f "/tmp/${FW_DEB}" "/tmp/${DKMS_DEB}"
download_file "${BASE_URL}/${FW_DEB}" "/tmp/${FW_DEB}"
download_file "${BASE_URL}/${DKMS_DEB}" "/tmp/${DKMS_DEB}"

if [[ "$DRY_RUN" == false ]]; then
  verify_deb_file "/tmp/${FW_DEB}"
  verify_deb_file "/tmp/${DKMS_DEB}"
  info "Removing stale firmware from previous installs"
  rm -rf /lib/firmware/aic8800D80
  info "Installing firmware package"
  dpkg -i "/tmp/${FW_DEB}"
  info "Installing DKMS package (compiling kernel module)"
  dpkg -i "/tmp/${DKMS_DEB}" || {
    warn "dpkg returned non-zero, attempting apt-get -f install"
    apt-get -f install -y
    dpkg -i "/tmp/${DKMS_DEB}"
  }
  verify_driver_post_install
else
  dryrun "dpkg -i $FW_DEB && dpkg -i $DKMS_DEB"
fi
fi # end SKIP_DRIVER check

# ─────────────────────────────────────────────────────────────────────
# STEP 4: Prepare customized config files via {{PLACEHOLDER}} replacement
# ─────────────────────────────────────────────────────────────────────
step "[4/8] Preparing customized configs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$DRY_RUN" == false ]]; then
  cp -a "$SCRIPT_DIR/etc" "$TMP_DIR/"

  backup_file "/etc/hostapd/hostapd.conf"
  backup_file "/etc/dnsmasq.d/travel-ap.conf"
  backup_file "/etc/NetworkManager/conf.d/99-aic-ap.conf"
  backup_file "/etc/systemd/system/aic8800-switch.service"
  backup_file "/etc/default/hostapd"

  # hostapd.conf — all {{PLACEHOLDER}} replacements
  # WPA_PSK is escaped to handle special chars (/, &, \)
  apply_template "$TMP_DIR/etc/hostapd/hostapd.conf" \
    LAN_IFACE    "$LAN_IFACE" \
    SSID         "$SSID" \
    CHANNEL      "$CHANNEL" \
    WPA_PSK      "$WPA_PSK" \
    COUNTRY_CODE "$COUNTRY_CODE"

  # dnsmasq.conf — all {{PLACEHOLDER}} replacements
  apply_template "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" \
    LAN_IFACE  "$LAN_IFACE" \
    DHCP_START "$DHCP_START" \
    DHCP_END   "$DHCP_END" \
    NETMASK    "$NETMASK" \
    LEASE_TIME "$LEASE_TIME" \
    AP_IP      "$AP_IP"

  if [[ "$USE_UNBOUND" =~ ^([Nn][Oo]|[Nn])$ ]]; then
    sed -i 's/^port=0/# port=0 disabled by installer/' "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" || true
    cat >> "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" <<'EODNS'

# Upstream DNS (Unbound disabled)
server=8.8.8.8
server=8.8.4.4
no-resolv
EODNS
  fi

  # NetworkManager unmanaged-devices
  cat > "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" <<EONM
[keyfile]
unmanaged-devices=interface-name:${LAN_IFACE}
EONM

  # aic8800-switch.service — {{PLACEHOLDER}} replacements
  apply_template "$TMP_DIR/etc/systemd/system/aic8800-switch.service" \
    LAN_IFACE "$LAN_IFACE" \
    AP_IP     "$AP_IP" \
    AP_CIDR   "$AP_CIDR"

  ok "Configs customized"
else
  dryrun "apply_template: patch hostapd.conf, dnsmasq.conf, NM, aic8800-switch.service via {{PLACEHOLDER}}"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 5: Copy configs to system
# ─────────────────────────────────────────────────────────────────────
step "[5/8] Installing config files to system"
if [[ "$DRY_RUN" == false ]]; then
  mkdir -p /etc/modprobe.d
  cp "$TMP_DIR/etc/modprobe.d/aic8800-blacklist.conf" /etc/modprobe.d/
  mkdir -p /etc/udev/rules.d
  cp "$TMP_DIR/etc/udev/rules.d/99-aic8800-switch.rules" /etc/udev/rules.d/
  mkdir -p /etc/systemd/system
  cp "$TMP_DIR/etc/systemd/system/aic8800-switch.service" /etc/systemd/system/
  mkdir -p /etc/systemd/system/hostapd.service.d
  cp "$TMP_DIR/etc/systemd/system/hostapd.service.d/wait-for-switch.conf" /etc/systemd/system/hostapd.service.d/
  mkdir -p /etc/systemd/system/dnsmasq.service.d
  cp "$TMP_DIR/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf" /etc/systemd/system/dnsmasq.service.d/
  mkdir -p /etc/hostapd
  cp "$TMP_DIR/etc/hostapd/hostapd.conf" /etc/hostapd/
  cp "$TMP_DIR/etc/default/hostapd" /etc/default/hostapd
  mkdir -p /etc/dnsmasq.d
  cp "$TMP_DIR/etc/dnsmasq.d/travel-ap.conf" /etc/dnsmasq.d/
  mkdir -p /etc/NetworkManager/conf.d
  cp "$TMP_DIR/etc/NetworkManager/conf.d/99-aic-ap.conf" /etc/NetworkManager/conf.d/
  ok "Config files installed"
else
  dryrun "Copy all config files to system /etc/ locations"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 6: Validate + configure system
# ─────────────────────────────────────────────────────────────────────
step "[6/8] Validating + configuring system"
if [[ "$DRY_RUN" == false ]]; then
  validate_hostapd_conf /etc/hostapd/hostapd.conf
fi
append_cmdline_quirk
enable_ip_forwarding
install_nat_rules "$WAN_IFACE" "$LAN_IFACE"
ok "System configuration complete"

# ─────────────────────────────────────────────────────────────────────
# STEP 7: Enable services
# ─────────────────────────────────────────────────────────────────────
step "[7/8] Enabling services"
if [[ "$DRY_RUN" == false ]]; then
  systemctl daemon-reload
  udevadm control --reload-rules
  update-initramfs -u 2>/dev/null || true
  systemctl restart NetworkManager 2>/dev/null || true
  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable aic8800-switch hostapd dnsmasq
  ok "Services enabled"
else
  dryrun "systemctl enable aic8800-switch hostapd dnsmasq"
fi

# ─────────────────────────────────────────────────────────────────────
# STEP 8: Summary
# ─────────────────────────────────────────────────────────────────────
step "[8/8] Installation complete"
echo
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ "$DRY_RUN" == true ]]; then
echo "║          DRY-RUN COMPLETE — no changes made                   ║"
else
echo "║                 Installation complete!                        ║"
fi
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-20s  %-37s ║\n" "WAN interface"   "$WAN_IFACE"
printf "║  %-20s  %-37s ║\n" "LAN/AP iface"    "$LAN_IFACE"
printf "║  %-20s  %-37s ║\n" "AP gateway"      "$AP_IP/$AP_CIDR"
printf "║  %-20s  %-37s ║\n" "DHCP range"      "$DHCP_START – $DHCP_END"
printf "║  %-20s  %-37s ║\n" "SSID"            "$SSID"
printf "║  %-20s  %-37s ║\n" "Country/Channel" "$COUNTRY_CODE / ch$CHANNEL"
printf "║  %-20s  %-37s ║\n" "AIC8800 version" "$AIC_VER"
[[ "$DRY_RUN" == false ]] && printf "║  %-20s  %-37s ║\n" "Backups saved" "$BACKUP_DIR"
echo "╠══════════════════════════════════════════════════════════════╣"
if [[ "$DRY_RUN" == false ]]; then
echo "║  Next: reboot                                                 ║"
echo "║    sudo reboot                                                ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  After reboot, verify:                                        ║"
echo "║    lsusb | grep a69c          (expect a69c:8d81)              ║"
printf "║    ip addr show %-45s ║\n" "$LAN_IFACE"
echo "║    systemctl status aic8800-switch hostapd dnsmasq            ║"
echo "║    dkms status                (aic8800-usb: installed)        ║"
echo "║    sudo bash status.sh        (full system health check)      ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
