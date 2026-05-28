#!/usr/bin/env bash
# ==============================================================
# AIC8800D80 Debug Collector
# https://github.com/OZAMNJ/aic8800d80-linux-fix
#
# Collects diagnostic information for bug reports and support.
# Run as: sudo bash collect-debug.sh
#
# Output: /tmp/aic8800-debug-<timestamp>.txt
# ==============================================================
set -euo pipefail

OUT="/tmp/aic8800-debug-$(date +%Y%m%d-%H%M%S).txt"
REPO_URL="https://github.com/OZAMNJ/aic8800d80-linux-fix"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

header()  { echo -e "${CYAN}${BOLD}=== $* ===${NC}"; }
section() { echo ""; echo "### $* ###"; }
run()     { echo "$ $*"; "$@" 2>&1 || echo "(command failed or not available)"; }

[[ $EUID -ne 0 ]] && echo -e "${RED}[WARN]${NC} Some checks require root. Re-run with sudo for full output."

echo -e "${BOLD}AIC8800D80 Debug Collector${NC}"
echo "Output: $OUT"
echo "Collecting... (this takes a few seconds)"
echo ""

# Redirect all output to both terminal and file
exec > >(tee "$OUT") 2>&1

echo "====================================================="
echo " AIC8800D80 Debug Report"
echo " Repo: $REPO_URL"
echo " Date: $(date -u)"
echo "====================================================="

# ── 1. System ──────────────────────────────────────────────
header "1. System Information"
run uname -a
run cat /etc/os-release
run cat /proc/version
run uptime
run free -h

# ── 2. Kernel / Secure Boot ────────────────────────────────
header "2. Kernel & Secure Boot"
run uname -r
if command -v mokutil &>/dev/null; then
  run mokutil --sb-state 2>/dev/null || echo "(mokutil failed)"
else
  echo "mokutil not installed — Secure Boot state unknown"
fi
[ -f /sys/firmware/efi ] && echo "Boot mode: UEFI" || echo "Boot mode: Legacy BIOS"

# ── 3. USB Device State ────────────────────────────────────
header "3. USB Device State"
echo "--- All USB devices ---"
run lsusb
echo ""
echo "--- AIC8800 specific (look for 1111:1111 or a69c:*) ---"
lsusb | grep -E '(1111:1111|a69c)' && echo "Found AIC8800 device" || echo "No AIC8800 device detected in lsusb"
echo ""
echo "--- USB tree ---"
run lsusb -t 2>/dev/null || echo "(lsusb -t not available)"

# ── 4. Kernel Modules ──────────────────────────────────────
header "4. Kernel Modules"
echo "--- All aic8800 related modules ---"
lsmod | grep -i aic8800 || echo "No aic8800 modules loaded"
echo ""
echo "--- Blacklist config ---"
cat /etc/modprobe.d/aic8800-blacklist.conf 2>/dev/null || echo "(blacklist conf not found — not installed)"
echo ""
echo "--- Module info (aic8800_fdrv_usb) ---"
modinfo aic8800_fdrv_usb 2>/dev/null || echo "(aic8800_fdrv_usb module not found)"

# ── 5. DKMS Status ─────────────────────────────────────────
header "5. DKMS Status"
if command -v dkms &>/dev/null; then
  run dkms status
  echo ""
  # Check for aic8800 specifically
  if dkms status | grep -q aic8800; then
    echo "PASS: aic8800 DKMS module present"
    dkms status | grep aic8800
  else
    echo "WARN: aic8800 not in dkms status"
  fi
else
  echo "DKMS not installed"
fi

# ── 6. Firmware ────────────────────────────────────────────
header "6. Firmware Files"
if [ -d /lib/firmware/aic8800D80 ]; then
  echo "Firmware directory exists:"
  ls -lh /lib/firmware/aic8800D80/
  echo ""
  echo "--- SHA256 hashes ---"
  sha256sum /lib/firmware/aic8800D80/* 2>/dev/null || echo "(sha256sum failed)"
else
  echo "WARN: /lib/firmware/aic8800D80 not found — firmware not installed"
fi

# ── 7. Network Interfaces ──────────────────────────────────
header "7. Network Interfaces"
run ip link show
echo ""
run ip addr show
echo ""
echo "--- wlan0 specifically ---"
ip link show wlan0 2>/dev/null || echo "wlan0 not found (dongle may not be in WiFi mode)"

# ── 8. cmdline.txt (USB quirk) ─────────────────────────────
header "8. Boot Cmdline (usb-storage.quirks)"
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt /proc/cmdline; do
  if [ -f "$f" ] || [ "$f" = "/proc/cmdline" ]; then
    echo "--- $f ---"
    cat "$f" 2>/dev/null
    echo ""
  fi
done
if cat /proc/cmdline | grep -q 'usb-storage.quirks=1111:1111:i'; then
  echo "PASS: usb-storage.quirks=1111:1111:i is active"
else
  echo "WARN: usb-storage.quirks NOT found in kernel cmdline"
fi

# ── 9. Systemd Services ────────────────────────────────────
header "9. Systemd Services"
for svc in aic8800-switch hostapd dnsmasq NetworkManager; do
  echo "--- $svc ---"
  systemctl status "$svc" --no-pager -l 2>/dev/null | head -20 || \
    echo "$svc: service not found"
  echo ""
done

# ── 10. Journalctl Excerpts ────────────────────────────────
header "10. Recent Journal (aic8800-switch)"
journalctl -u aic8800-switch.service --no-pager -n 50 2>/dev/null || \
  echo "(aic8800-switch.service journal not available)"

echo ""
header "10b. Kernel messages (aic8800 / usb)"
dmesg 2>/dev/null | grep -iE '(aic8800|a69c|1111:1111|usb.*modeswitch|aic_load)' | tail -30 || \
  echo "(no relevant dmesg entries found)"

# ── 11. Installed Packages ─────────────────────────────────
header "11. Installed AIC8800 Packages"
dpkg -l | grep -i aic8800 2>/dev/null || echo "No aic8800 packages found via dpkg"

# ── 12. Repo/Install State ─────────────────────────────────
header "12. Install State"
echo "--- Config files present ---"
for f in \
  /etc/modprobe.d/aic8800-blacklist.conf \
  /etc/udev/rules.d/99-aic8800-switch.rules \
  /etc/systemd/system/aic8800-switch.service \
  /etc/NetworkManager/conf.d/99-aic-ap.conf \
  /etc/hostapd/hostapd.conf \
  /etc/dnsmasq.d/travel-ap.conf; do
  [ -f "$f" ] && echo "PRESENT: $f" || echo "ABSENT:  $f"
done

# ── 13. NetworkManager ─────────────────────────────────────
header "13. NetworkManager"
cat /etc/NetworkManager/conf.d/99-aic-ap.conf 2>/dev/null || \
  echo "(99-aic-ap.conf not found)"
echo ""
nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null || echo "nmcli not available"

# ── 14. Summary ────────────────────────────────────────────
header "14. Summary"
USB_OK=false; QUIRK_OK=false; DKMS_OK=false; FW_OK=false; SVC_OK=false
lsusb | grep -qE 'a69c' && USB_OK=true
cat /proc/cmdline | grep -q 'usb-storage.quirks=1111:1111:i' && QUIRK_OK=true
dkms status 2>/dev/null | grep -q aic8800 && DKMS_OK=true
[ -d /lib/firmware/aic8800D80 ] && FW_OK=true
systemctl is-active aic8800-switch.service &>/dev/null && SVC_OK=true

echo "USB device in WiFi mode (a69c:*) : $($USB_OK && echo YES || echo NO)"
echo "usb-storage.quirks active        : $($QUIRK_OK && echo YES || echo NO)"
echo "DKMS module registered           : $($DKMS_OK && echo YES || echo NO)"
echo "Firmware files present           : $($FW_OK && echo YES || echo NO)"
echo "aic8800-switch.service active    : $($SVC_OK && echo YES || echo NO)"

echo ""
echo "====================================================="
echo " Debug report saved to: $OUT"
echo " Please attach this file to your GitHub issue or"
echo " paste it at https://gist.github.com"
echo "====================================================="
