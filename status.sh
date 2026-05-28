#!/usr/bin/env bash
# status.sh — AIC8800D80 Travel Router health check
# https://github.com/OZAMNJ/aic8800d80-linux-fix
#
# Run as: sudo bash status.sh
#
# Copyright (C) 2025 OZAMNJ
# SPDX-License-Identifier: MIT

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
hdr()  { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

FAIL_COUNT=0
check() {
  local label="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
    (( FAIL_COUNT++ )) || true
  fi
}

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         AIC8800D80 Travel Router — System Status              ║"
echo "╚══════════════════════════════════════════════════════════════╝"

hdr "USB Device"
if lsusb | grep -q "a69c:8d81"; then
  ok "AIC8800D80 found as WiFi adapter (a69c:8d81)"
elif lsusb | grep -q "1111:1111"; then
  fail "AIC8800D80 stuck in CD-ROM mode (1111:1111) — modeswitch failed"
  (( FAIL_COUNT++ )) || true
elif lsusb | grep -q "a69c:8d80"; then
  warn "AIC8800D80 in firmware loader mode (a69c:8d80) — driver still loading"
else
  warn "AIC8800D80 not detected via lsusb — check USB connection"
fi
lsusb | grep -i "a69c\|1111:1111" | sed 's/^/    /' || echo "    (no a69c or 1111:1111 device found)"

hdr "DKMS / Kernel Module"
if dkms status 2>/dev/null | grep -q "aic8800"; then
  dkms status | grep aic8800 | sed 's/^/    /'
  dkms status | grep -q "aic8800.*installed" && ok "DKMS module: installed" || warn "DKMS module: built but not installed (reboot needed?)"
else
  fail "aic8800 not found in dkms status"
  (( FAIL_COUNT++ )) || true
fi
if lsmod | grep -q "aic8800"; then
  ok "aic8800 kernel module loaded"
  lsmod | grep aic8800 | sed 's/^/    /'
else
  warn "aic8800 module not loaded (normal before first boot)"
fi

hdr "Firmware"
if [[ -d /lib/firmware/aic8800D80 ]]; then
  ok "Firmware directory present: /lib/firmware/aic8800D80/"
  ls /lib/firmware/aic8800D80/ | head -5 | sed 's/^/    /'
else
  fail "Firmware missing: /lib/firmware/aic8800D80/"
  (( FAIL_COUNT++ )) || true
fi

hdr "Services"
for svc in aic8800-switch hostapd dnsmasq; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    STATE="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
    if [[ "$STATE" == "active" ]]; then
      ok "$svc: enabled + active"
    else
      warn "$svc: enabled but $STATE"
    fi
  else
    fail "$svc: not enabled"
    (( FAIL_COUNT++ )) || true
  fi
done

hdr "Network Interfaces"
AP_IFACE="${LAN_IFACE:-wlan0}"
if ip link show "$AP_IFACE" >/dev/null 2>&1; then
  ok "Interface $AP_IFACE exists"
  ip addr show "$AP_IFACE" | grep -E "inet |state " | sed 's/^/    /'
else
  fail "Interface $AP_IFACE not found — driver may not be loaded yet"
  (( FAIL_COUNT++ )) || true
fi

hdr "hostapd Config"
if [[ -f /etc/hostapd/hostapd.conf ]]; then
  ok "/etc/hostapd/hostapd.conf present"
  REMAINING=$(grep -oP '\{\{[^}]+\}\}' /etc/hostapd/hostapd.conf | sort -u || true)
  if [[ -n "$REMAINING" ]]; then
    warn "Unreplaced placeholders: $REMAINING"
  else
    ok "No unreplaced placeholders"
  fi
  grep -E "^ssid=|^channel=|^country_code=|^interface=" /etc/hostapd/hostapd.conf | sed 's/^/    /'
else
  fail "/etc/hostapd/hostapd.conf missing"
  (( FAIL_COUNT++ )) || true
fi

hdr "cmdline.txt quirk"
if grep -q "usb-storage.quirks=1111:1111:i" /boot/firmware/cmdline.txt 2>/dev/null; then
  ok "usb-storage quirk present in cmdline.txt"
else
  fail "usb-storage.quirks=1111:1111:i missing from /boot/firmware/cmdline.txt"
  (( FAIL_COUNT++ )) || true
fi

hdr "IP Forwarding"
if [[ "$(cat /proc/sys/net/ipv4/ip_forward)" == "1" ]]; then
  ok "IPv4 forwarding enabled"
else
  fail "IPv4 forwarding disabled"
  (( FAIL_COUNT++ )) || true
fi

hdr "NAT Rules"
if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
  ok "MASQUERADE rule present in iptables"
else
  warn "No MASQUERADE rule found — NAT may not be configured"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════"
if (( FAIL_COUNT == 0 )); then
  echo -e "  ${GREEN}All checks passed — system looks healthy${NC}"
else
  echo -e "  ${RED}${FAIL_COUNT} check(s) failed — review items above${NC}"
  echo "  Run: sudo journalctl -u aic8800-switch -u hostapd -u dnsmasq -n 50 --no-pager"
  echo "  Or:  sudo bash collect-debug.sh"
fi
echo "══════════════════════════════════════════════════════════════"
echo
