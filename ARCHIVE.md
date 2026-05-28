# AIC8800D80 — Manual Configuration Archive

> **Note:** The [automated installer](install.sh) handles everything below in one interactive session.
> This document is preserved for advanced users, contributors, and those debugging specific steps.
> **Most users should run `sudo bash install.sh` instead.**

---

## Who This Guide Is For

This is for people who:
- Want to understand *why* each step is needed
- Are adapting the setup to a different distro or kernel
- Are debugging a failed install
- Want to cherry-pick specific steps

---

## Root Causes — Why This Is Hard

The AIC8800D80 dongle has **four stacked problems** that must all be solved simultaneously:

1. **USB ID 1111:1111 (CD-ROM mode at boot)** — The dongle powers on in mass-storage/CD-ROM mode. A `usb_modeswitch` command must be sent before the WiFi driver can bind.

2. **`usb-storage` kernel module hijack** — The kernel's USB storage driver sees `1111:1111` and claims the device before modeswitch can run. Fix: add `usb-storage.quirks=1111:1111:i` to `/boot/firmware/cmdline.txt`.

3. **Two-stage firmware upload (a69c:8d80 → a69c:8d81)** — After modeswitch the device appears as `a69c:8d80` (firmware loader). `aic_load_fw_usb` uploads firmware and it re-enumerates as `a69c:8d81` (WiFi). This takes ~15-19 seconds.

4. **Boot timing race** — `hostapd` and `dnsmasq` start before `wlan0` exists. Fix: custom systemd service with a dynamic wait loop + drop-in `After=` dependencies.

---

## Step 1 — Protect SSH

Before making network changes, ensure SSH stays on the wired interface:

```bash
sudo nmcli connection modify "$(nmcli -t -f NAME,TYPE con show | grep ethernet | head -1 | cut -d: -f1)" \
  ipv4.method manual ipv4.addresses 192.168.1.100/24 ipv4.gateway 192.168.1.1
```

Or simply: keep your SSH session on `eth0`/the wired port throughout.

---

## Step 2 — Tell NetworkManager to Ignore `wlan0`

Create `/etc/NetworkManager/conf.d/99-aic-ap.conf`:

```ini
[keyfile]
unmanaged-devices=interface-name:wlan0
```

Then reload:
```bash
sudo systemctl reload NetworkManager
```

---

## Step 3 — Install AIC8800D80 Driver (DKMS)

```bash
# Download the official Radxa packages
wget https://github.com/radxa-pkg/aic8800/releases/latest/download/aic8800-firmware_*.deb
wget https://github.com/radxa-pkg/aic8800/releases/latest/download/aic8800-usb-dkms_*.deb

# Install prerequisites
sudo apt install -y dkms linux-headers-$(uname -r)

# Install packages
sudo dpkg -i aic8800-firmware_*.deb aic8800-usb-dkms_*.deb
sudo apt install -f  # Fix any dependency issues
```

Verify DKMS built the module:
```bash
dkms status | grep aic8800
# Expected: aic8800_usb, <version>, <kernel>, installed
```

---

## Step 4 — Blacklist Conflicting Modules & Fix `usb-storage`

### 4.1 Blacklist non-USB driver variants

Create `/etc/modprobe.d/aic8800-blacklist.conf`:
```
# Blacklist non-USB variants — only aic8800_fdrv_usb should load
blacklist aic8800_fdrv
blacklist aic8800_btusb
```

Update initramfs:
```bash
sudo update-initramfs -u
```

### 4.2 Prevent `usb-storage` from hijacking CD-ROM mode

Edit `/boot/firmware/cmdline.txt` — add to the **same line** (no newline):
```
usb-storage.quirks=1111:1111:i
```

The `i` flag means "ignore" (don't claim this device).

---

## Step 5 — Create the USB Modeswitch Service

Create `/etc/udev/rules.d/99-aic8800-switch.rules`:
```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1111", ATTR{idProduct}=="1111", \
  RUN+="/bin/systemctl start aic8800-switch.service"
```

Create `/etc/systemd/system/aic8800-switch.service` (see `etc/systemd/system/aic8800-switch.service` in this repo — the installer templates it with your chosen interface and IP).

Reload udev and systemd:
```bash
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
```

---

## Step 6 — Install and Configure `hostapd`

```bash
sudo apt install -y hostapd
sudo systemctl unmask hostapd
```

Create `/etc/hostapd/hostapd.conf` (see `etc/hostapd/hostapd.conf` in this repo for the template).

Create the wait-for-switch drop-in at `/etc/systemd/system/hostapd.service.d/wait-for-switch.conf`:
```ini
[Unit]
After=aic8800-switch.service
Requires=aic8800-switch.service
```

---

## Step 7 — Install and Configure `dnsmasq` (DHCP)

```bash
sudo apt install -y dnsmasq
```

Create `/etc/dnsmasq.d/travel-ap.conf` (see `etc/dnsmasq.d/travel-ap.conf` in this repo).

Create the wait-for-switch drop-in at `/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf`:
```ini
[Unit]
After=aic8800-switch.service
Requires=aic8800-switch.service
```

---

## Step 8 — NAT and IP Forwarding (Internet Sharing)

### Enable IP forwarding
```bash
sudo sed -i 's|^#*net.ipv4.ip_forward.*|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sysctl -p
```

### Install and apply iptables NAT rules
```bash
sudo apt install -y iptables-persistent netfilter-persistent

# Replace eth0/wlan0 with your actual WAN/LAN interfaces
WAN=eth0
LAN=wlan0

iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
iptables -A FORWARD -i $WAN -o $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT

sudo netfilter-persistent save
```

---

## Step 9 — Final Reboot Test

```bash
sudo reboot
```

After reboot, verify:
```bash
# Confirm dongle is in WiFi mode (not CD-ROM)
lsusb | grep a69c
# Expected: ... a69c:8d81 ...

# Check interface is up
ip link show wlan0

# Check hostapd is running
sudo systemctl status hostapd

# Check dnsmasq is running
sudo systemctl status dnsmasq

# Test WiFi from a phone — connect to your SSID
```

---

## Troubleshooting

### Dongle still shows as 1111:1111 after reboot
- Check `usb-storage.quirks=1111:1111:i` is in `/boot/firmware/cmdline.txt` on the same line
- Run `sudo update-initramfs -u` and reboot again

### `wlan0` never appears
- Check `dkms status | grep aic8800` shows `installed`
- Check `journalctl -u aic8800-switch.service` for errors
- Try manually: `sudo modprobe aic8800_fdrv_usb`

### `hostapd` fails with "unknown interface wlan0"
- The race condition — `wlan0` wasn't ready when `hostapd` started
- Check `aic8800-switch.service` is enabled and the drop-in files exist

### WiFi clients can connect but have no internet
- Check NAT rules: `sudo iptables -t nat -L -n`
- Check IP forwarding: `cat /proc/sys/net/ipv4/ip_forward` (should be `1`)

---

## Key Lessons (Hard Won)

- **Single-message modeswitch payload** — The `555342...f2` payload is more reliable than the standard 3-message approach used by most `usb_modeswitch` configs online.
- **19-second wait is real** — The dongle genuinely takes 15-19 seconds to fully enumerate after firmware upload. Fixed sleeps break on slower hardware; the dynamic loop in the service is essential.
- **NetworkManager must be excluded** — Without the `unmanaged-devices` config, NetworkManager constantly tries to reconfigure `wlan0`, conflicting with `hostapd`.
- **DKMS not `make install`** — Using the official `aic8800-usb-dkms` package means the driver survives kernel upgrades automatically.

---

*This archive is maintained for reference. For the latest automated setup, see [install.sh](install.sh).*
