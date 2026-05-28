#!/usr/bin/env bash
# =============================================================
# AIC8800D80 Linux Fix — Uninstaller
# https://github.com/OZAMNJ/aic8800d80-linux-fix
# Run as: sudo bash uninstall.sh
#
# Removes everything installed by install.sh:
#   - AIC8800 DKMS driver + firmware packages
#   - All config files deployed to /etc/
#   - Systemd services and drop-ins
#   - NAT / iptables rules
#   - usb-storage.quirks from /boot/firmware/cmdline.txt
# =============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}==>${NC} ${BOLD}$*${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Run as root: sudo bash uninstall.sh" >&2; exit 1; }

QUIRK="usb-storage.quirks=1111:1111:i"
CMDLINE_FILE="/boot/firmware/cmdline.txt"

echo -e "\n${CYAN}${BOLD}============================================================${NC}"
echo -e "${BOLD} AIC8800D80 — Uninstaller${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}\n"
read -r -p "This will remove all AIC8800D80 config files and services. Continue? (yes/no) [no]: " CONFIRM
[[ "$CONFIRM" =~ ^([Yy][Ee][Ss]|[Yy])$ ]] || { echo "Aborted."; exit 0; }
echo

# ──────────────────────── Stop + disable services
info "Stopping and disabling services"
for svc in aic8800-switch hostapd dnsmasq; do
  systemctl stop "$svc"    2>/dev/null && ok "Stopped $svc"    || warn "$svc was not running"
  systemctl disable "$svc" 2>/dev/null && ok "Disabled $svc"   || warn "$svc was not enabled"
done

# ──────────────────────── Remove config files
info "Removing config files"
rm -fv /etc/modprobe.d/aic8800-blacklist.conf
rm -fv /etc/udev/rules.d/99-aic8800-switch.rules
rm -fv /etc/systemd/system/aic8800-switch.service
rm -rfv /etc/systemd/system/hostapd.service.d/wait-for-switch.conf
rm -rfv /etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf
rm -fv /etc/hostapd/hostapd.conf
rm -fv /etc/default/hostapd
rm -fv /etc/dnsmasq.d/travel-ap.conf
rm -fv /etc/NetworkManager/conf.d/99-aic-ap.conf
ok "Config files removed"

# ──────────────────────── Remove DKMS driver + firmware
info "Removing AIC8800 DKMS driver and firmware"
if dpkg -l 2>/dev/null | grep -q aic8800-usb-dkms; then
  apt purge -y aic8800-usb-dkms && ok "aic8800-usb-dkms removed"
else
  warn "aic8800-usb-dkms not installed, skipping"
fi
if dpkg -l 2>/dev/null | grep -q aic8800-firmware; then
  apt purge -y aic8800-firmware && ok "aic8800-firmware removed"
else
  warn "aic8800-firmware not installed, skipping"
fi
rm -rf /lib/firmware/aic8800D80 && ok "Firmware directory removed" || true

# ──────────────────────── Remove NAT rules
info "Flushing NAT and FORWARD iptables rules"
iptables -t nat -F POSTROUTING 2>/dev/null && ok "NAT POSTROUTING flushed" || warn "Could not flush NAT rules"
iptables -F FORWARD 2>/dev/null && ok "FORWARD chain flushed" || warn "Could not flush FORWARD chain"
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null && ok "iptables rules saved (cleared)" || true
fi

# ──────────────────────── Remove usb-storage.quirks from cmdline.txt
info "Removing $QUIRK from $CMDLINE_FILE"
if [[ -f "$CMDLINE_FILE" ]] && grep -q "$QUIRK" "$CMDLINE_FILE"; then
  cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i "s| ${QUIRK}||g; s|${QUIRK} ||g; s|${QUIRK}||g" "$CMDLINE_FILE"
  ok "$QUIRK removed from $CMDLINE_FILE"
else
  warn "$QUIRK not found in $CMDLINE_FILE (already clean)"
fi

# ──────────────────────── Unload kernel modules
info "Unloading AIC8800 kernel modules"
for mod in aic8800_fdrv_usb aic_load_fw_usb; do
  rmmod "$mod" 2>/dev/null && ok "Unloaded $mod" || warn "$mod not loaded"
done

# ──────────────────────── Reload systemd + udev
info "Reloading systemd and udev"
systemctl daemon-reload
udevadm control --reload-rules
update-initramfs -u 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
ok "systemd and udev reloaded"

echo
echo "============================================================"
echo " Uninstall complete!"
echo "============================================================"
echo " All AIC8800D80 config files, services, and DKMS driver"
echo " have been removed."
echo
echo " Reboot to complete cleanup:"
echo "   sudo reboot"
echo
echo " After reboot, your USB dongle will return to CD-ROM mode"
echo " (1111:1111) until you run install.sh again."
echo "============================================================"
