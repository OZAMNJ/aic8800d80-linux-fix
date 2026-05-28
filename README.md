# AIC8800D80 WiFi 6 USB Dongle — Complete Linux Fix & Travel Router Guide

> **Verified working on Raspberry Pi OS Bookworm (Kernel 6.12.75+)**  
> Solves the CD-ROM mode problem permanently and builds a fully automatic WiFi Access Point with internet sharing.

![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Raspberry%20Pi-blue)
![Kernel](https://img.shields.io/badge/kernel-6.12%2B-green)
![Chipset](https://img.shields.io/badge/chipset-AIC8800D80-orange)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

---

<!-- SEO KEYWORDS
aic8800d80 linux driver
aic8800d80 raspberry pi
aic8800 usb wifi dongle linux fix
usb wifi adapter shows as cd-rom linux
usb modeswitch aic8800
1111:1111 usb id linux
a69c:8d81 linux driver
wifi 6 usb dongle linux not working
aic8800_fdrv_usb dkms
radxa-pkg aic8800
hostapd dnsmasq raspberry pi access point
usb-storage quirks 1111:1111
wlan0 not showing after modeswitch
raspberry pi wifi hotspot bookworm
linux travel router raspberry pi
usb wifi dongle cd-rom mode fix
usb mass storage mode wifi adapter
usb_modeswitch systemd service
networkmanager unmanaged-devices wlan0
iptables nat masquerade linux wifi sharing
aic8800 dkms install bookworm
Raspbian Bookworm WiFi AP setup
linux wifi dongle not detected fix
usb wifi adapter keeps disconnecting linux
Bootworm dhcpcd replacement networkmanager
-->

## Who This Guide Is For

Any Linux user with a cheap USB WiFi 6 dongle that refuses to work — showing up as a virtual CD-ROM instead of a WiFi adapter. This is an extremely common problem with AIC8800D80-based dongles sold under dozens of generic brand names on Amazon, AliExpress, and eBay.

**Common search terms that lead here:**
- USB WiFi adapter shows as CD-ROM drive in Linux
- `lsusb` shows `1111:1111` — WiFi dongle not working
- AIC8800 / AIC8800D80 driver not loading on Raspberry Pi
- `wlan0` not created after USB modeswitch
- hostapd fails with "unknown interface wlan0" at boot
- WiFi 6 USB dongle Linux driver DKMS install
- Cheap WiFi dongle stuck in Mass Storage mode Linux
- `a69c:8d80` stuck — never reaches `a69c:8d81`
- `aic8800_fdrv` vs `aic8800_fdrv_usb` — which module to use
- Raspberry Pi travel router Bookworm 2024/2025

## Affected Devices

If your dongle shows this in `lsusb`, this guide is for you:

```
ID 1111:1111 Pandora International Ltd. 88M80
```

After the fix it becomes:

```
ID a69c:8d81 AICSemi AIC 8800D80
```

**Verified device descriptor (from working device):**

```
idVendor    0xa69c
idProduct   0x8d81
iManufacturer  AICSemi
iProduct       AIC 8800D80
iSerial        20220103
bDeviceClass   239 Miscellaneous Device
MaxPower       500mA
bNumConfigurations  1
```

## Tested Hardware & Software

| Item | Detail |
|---|---|
| Board | Raspberry Pi 2 Model B (also works on Pi 3/4/5) |
| OS | Raspbian GNU/Linux 12 (Bookworm) |
| Kernel | `6.12.75+rpt-rpi-v7` (armv7l) |
| Dongle | AIC8800D80 — USB ID `1111:1111` → `a69c:8d81` |
| Internet uplink | `eth0` — wired to ISP/hotel router |
| AP subnet | `192.168.73.0/24` on `wlan0` |

## Why This Is Hard — The Root Causes

The AIC8800D80 has **four separate failure modes** that must all be solved:

| Problem | Symptom | Root Cause |
|---|---|---|
| CD-ROM mode | `lsusb` shows `1111:1111` forever | Device boots as USB Mass Storage by design |
| usb-storage hijack | Device never switches even after modeswitch command | `usb-storage` kernel driver grabs it at boot before modeswitch can run |
| Wrong kernel modules | `wlan0` never appears after switch | Old `aic8800_fdrv` / `aic_load_fw` modules (without `_usb` suffix) conflict with the correct radxa-pkg `_usb` variants |
| Boot timing race | `hostapd`/`dnsmasq` fail at boot with "unknown interface wlan0" | The dongle takes ~19 seconds to fully switch and load — services start too early |

All four must be fixed. This guide fixes all four.

## Architecture

```
[WiFi Clients] 192.168.73.x / WPA2
        │
        ▼
[AIC8800D80 — wlan0 — 192.168.73.1]
        │
[hostapd — AP mode]  [dnsmasq — DHCP server]  [iptables — NAT/MASQUERADE]
        │
[eth0 — wired uplink]
        │
[ISP / Hotel Router — Internet]
```

## Personalise Before You Start

This guide uses specific IP addresses and network values that **you must adapt to your own setup**. Find and replace these values everywhere they appear before running any commands:

| Placeholder used in this guide | What it means | How to find yours |
|---|---|---|
| `192.168.73.1` | Static IP assigned to `wlan0` (the AP gateway) | Choose any private subnet not already used on your network |
| `192.168.73.0/24` | The AP subnet | Must match your chosen gateway |
| `192.168.73.10–100` | DHCP range given to WiFi clients | Must be within your AP subnet |
| `eth0` | Your wired internet uplink interface | Run `ip link show` |
| `wlan0` | Your WiFi AP interface (the dongle) | Run `ip link show` after driver loads |
| `country_code=DE` | WiFi regulatory domain | Use your 2-letter country code |
| `channel=6` | WiFi channel | Use 1, 6, or 11 for 2.4GHz |

> **Quick check before continuing:** Run `ip link show` and `ip route` now to note your interface names and existing subnet. Make sure your chosen AP subnet does **not** overlap with your LAN subnet.

---

## Step 1 — Protect SSH Before Anything Else

> **Do this first.** All WiFi work is on `wlan0`. Your SSH session is on `eth0` and must never be lost.

```bash
sudo apt install -y iptables-persistent
sudo iptables -I INPUT 1 -i eth0 -p tcp --dport 22 -j ACCEPT
sudo iptables -I INPUT 2 -i eth0 -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo netfilter-persistent save
```

## Step 2 — Tell NetworkManager to Ignore wlan0

Raspberry Pi OS Bookworm uses NetworkManager. If it tries to manage `wlan0` it will fight with `hostapd`.

```bash
sudo tee /etc/NetworkManager/conf.d/99-aic-ap.conf << 'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
sudo systemctl restart NetworkManager
```

> **Note:** Do NOT add `wlan0` to `dhcpcd.conf`. Bookworm Lite does not have `dhcpcd` installed — those settings are silently ignored.

## Step 3 — Install AIC8800D80 Driver (DKMS)

Use the **radxa-pkg** pre-built `.deb` packages only. Do **not** use the `shenmintao/install.sh` script.

```bash
sudo apt install -y dkms linux-headers-$(uname -r)
wget https://github.com/radxa-pkg/aic8800/releases/download/4.0%2Bgit20250410.b99ca8b6-3/aic8800-firmware_4.0+git20250410.b99ca8b6-3_all.deb
wget https://github.com/radxa-pkg/aic8800/releases/download/4.0%2Bgit20250410.b99ca8b6-3/aic8800-usb-dkms_4.0+git20250410.b99ca8b6-3_all.deb

# Remove any stale firmware from previous attempts
sudo rm -rf /lib/firmware/aic8800D80
sudo dpkg -i aic8800-firmware_4.0+git20250410.b99ca8b6-3_all.deb
sudo dpkg -i aic8800-usb-dkms_4.0+git20250410.b99ca8b6-3_all.deb
```

Verify the DKMS build succeeded:

```bash
dkms status
uname -r
```

Expected output:
```
aic8800-usb/4.0+git20250410.b99ca8b6-3, 6.12.75+rpt-rpi-v7, armv7l: installed
```

> **Critical:** The kernel version in `dkms status` must exactly match `uname -r`. If you update the kernel later, run `sudo dpkg-reconfigure aic8800-usb-dkms` to rebuild.

The correct module names installed by radxa-pkg use the `_usb` suffix:
- `aic8800_fdrv_usb` — main WiFi driver
- `aic_load_fw_usb` — firmware loader
- `aic_btusb_usb` — Bluetooth driver

## Step 4 — Blacklist Conflicting Modules & Fix usb-storage

This is the most important step. Two things must happen:
1. The old non-`_usb` modules must be blacklisted
2. `usb-storage` must be prevented from grabbing the device before modeswitch runs

### 4.1 — Blacklist old modules

```bash
sudo tee /etc/modprobe.d/aic8800-blacklist.conf << 'EOF'
# Block old non-usb modules — radxa-pkg _usb variants are the correct ones
blacklist aic8800_fdrv
blacklist aic_load_fw
blacklist aic_btusb
# Fallback quirk (belt-and-suspenders with cmdline.txt)
options usb-storage quirks=1111:1111:i
EOF
sudo update-initramfs -u
```

### 4.2 — Block usb-storage via kernel boot parameter

Edit `/boot/firmware/cmdline.txt`:

```bash
sudo nano /boot/firmware/cmdline.txt
```

Add `usb-storage.quirks=1111:1111:i` to the **end of the single line**:

```
console=serial0,115200 console=tty1 root=PARTUUID=xxxxxxxx-02 rootfstype=ext4 fsck.repair=yes rootwait cfg80211.ieee80211_regdom=DE usb-storage.quirks=1111:1111:i
```

> **Warning:** `cmdline.txt` must be exactly one line. Verify with `cat /boot/firmware/cmdline.txt`.

## Step 5 — Create the USB Modeswitch Service

A systemd service is used instead of a udev rule because udev kills child processes before the 3-stage firmware switch completes.

### 5.1 — Create the udev rule

```bash
sudo tee /etc/udev/rules.d/99-aic8800-switch.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", \
  ATTR{idVendor}=="1111", ATTR{idProduct}=="1111", \
  TAG+="systemd", \
  ENV{SYSTEMD_WANTS}="aic8800-switch.service"
EOF
```

### 5.2 — Create the switch service

```bash
sudo tee /etc/systemd/system/aic8800-switch.service << 'EOF'
[Unit]
Description=AIC8800D80 USB Modeswitch
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Send single-message modeswitch — device disconnects and re-enumerates
ExecStart=/usr/sbin/usb_modeswitch \
  -v 0x1111 -p 0x1111 \
  -M "555342438765432100000000000010fd0000000000000000000000000000f2"
# Wait for firmware stage 1→2→3 re-enumeration
ExecStartPost=/bin/sleep 10
# Load firmware downloader (triggers a69c:8d80 → a69c:8d81 transition)
ExecStartPost=/sbin/modprobe aic_load_fw_usb
ExecStartPost=/bin/sleep 5
# Load main WiFi driver (creates wlan0)
ExecStartPost=/sbin/modprobe aic8800_fdrv_usb
ExecStartPost=/bin/sleep 3
# Assign static IP and bring interface up
# ⚠ CHANGE 192.168.73.1/24 to your chosen AP gateway/subnet
ExecStartPost=-/sbin/ip addr add 192.168.73.1/24 dev wlan0
ExecStartPost=-/sbin/ip link set wlan0 up
ExecStartPost=-/sbin/iw dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

**Verified boot sequence from dmesg:**

```
[ 5.8s] usb 1-1.5: New USB device found, idVendor=1111, idProduct=1111  ← CD-ROM mode
[24.6s] usb 1-1.5: USB disconnect                                        ← modeswitch fired
[24.9s] usb 1-1.5: New USB device found, idVendor=a69c, idProduct=8d80  ← firmware loading
[26.9s] aic_load_fw_usb probes, downloads firmware files
[27.4s] usb 1-1.5: USB disconnect                                        ← firmware complete
[28.2s] usb 1-1.5: New USB device found, idVendor=a69c, idProduct=8d81  ← WiFi mode ✓ wlan0 created
```

## Step 6 — Install and Configure hostapd

```bash
sudo apt install -y hostapd
sudo systemctl unmask hostapd
```

Create the AP configuration:

```bash
sudo tee /etc/hostapd/hostapd.conf << 'EOF'
interface=wlan0
driver=nl80211
ssid=YourSSIDHere          # ⚠ CHANGE — your network name
hw_mode=g
channel=6                  # ⚠ CHANGE — use 1, 6, or 11
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=YourPasswordHere  # ⚠ CHANGE — minimum 8 characters
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
country_code=DE            # ⚠ CHANGE — your 2-letter country code
ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]
EOF
```

Point hostapd to the config:

```bash
sudo tee /etc/default/hostapd << 'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
```

**Force hostapd to wait for the switch service:**

```bash
sudo mkdir -p /etc/systemd/system/hostapd.service.d
sudo tee /etc/systemd/system/hostapd.service.d/wait-for-switch.conf << 'EOF'
[Unit]
After=aic8800-switch.service
Requires=aic8800-switch.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable hostapd
```

## Step 7 — Install and Configure dnsmasq (DHCP)

```bash
sudo apt install -y dnsmasq
```

```bash
sudo tee /etc/dnsmasq.d/travel-ap.conf << 'EOF'
# port=0 disables dnsmasq DNS so Unbound or system DNS can use port 53
port=0
interface=wlan0
bind-interfaces
# ⚠ CHANGE both IPs below to match your chosen AP subnet
dhcp-range=192.168.73.10,192.168.73.100,255.255.255.0,24h
dhcp-option=3,192.168.73.1  # Gateway — must match wlan0 IP in switch service
dhcp-option=6,192.168.73.1  # DNS — same as gateway (Unbound listens here)
EOF
```

> If you are **not** installing Unbound, remove `port=0` and add DNS upstreams:
> ```
> server=8.8.8.8
> server=8.8.4.4
> no-resolv
> ```

**Force dnsmasq to wait for the switch service:**

```bash
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
sudo tee /etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf << 'EOF'
[Unit]
After=aic8800-switch.service
Requires=aic8800-switch.service
EOF
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
```

## Step 8 — NAT and IP Forwarding (Internet Sharing)

```bash
# Enable IP forwarding permanently
sudo sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sudo sysctl -p

# NAT rules — share eth0 internet to wlan0 clients
# ⚠ CHANGE eth0 if your uplink interface has a different name
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

# Save permanently
sudo netfilter-persistent save
```

## Step 9 — Final Reboot Test

```bash
sudo reboot
```

After reboot, verify everything came up automatically:

```bash
# Dongle must be in WiFi mode
lsusb | grep a69c
# Expected: Bus 001 Device 006: ID a69c:8d81 AICSemi AIC 8800D80

# wlan0 must have AP IP
ip addr show wlan0 | grep 192.168.73.1

# All services running
sudo systemctl status aic8800-switch hostapd dnsmasq --no-pager

# Boot timing (switch service should be ~19s)
systemd-analyze blame | head -10
```

**Expected output:**

```
● aic8800-switch.service  Active: active (exited)  ← oneshot — exited is correct
● hostapd.service         Active: active (running)  wlan0: AP-ENABLED
● dnsmasq.service         Active: active (running)  DHCP, sockets bound exclusively to interface wlan0
```

**Verified boot timing on Pi 2:**

```
19.072s aic8800-switch.service  ← dongle switch + firmware load
 6.003s tailscaled.service
 4.127s unbound.service
 2.452s ssh.service
```

---

## Troubleshooting

### "unknown interface wlan0" in hostapd or dnsmasq logs

Verify the drop-in files exist:

```bash
cat /etc/systemd/system/hostapd.service.d/wait-for-switch.conf
cat /etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf
```

Both must contain `After=aic8800-switch.service` and `Requires=aic8800-switch.service`.

### lsusb still shows 1111:1111 after reboot

```bash
# 1. Is usb-storage still grabbing it?
sudo dmesg | grep -E "1111|usb-storage|Mass Storage"
# 2. Did cmdline.txt get the quirk?
cat /boot/firmware/cmdline.txt | grep quirks
# 3. Did the switch service run?
sudo journalctl -u aic8800-switch --no-pager
```

### wlan0 appears but hostapd fails to start

```bash
sudo hostapd -dd /etc/hostapd/hostapd.conf
```

Common causes: wrong `country_code`, invalid `channel` for region, or `ieee80211ax=1` not supported (remove it for 2.4GHz-only on Pi 2).

### Conflicting kernel modules

```bash
lsmod | grep aic
# Bad:  aic8800_fdrv, aic_load_fw  (no _usb)
# Good: aic8800_fdrv_usb, aic_load_fw_usb
```

Fix: ensure `/etc/modprobe.d/aic8800-blacklist.conf` has both blacklist entries and run `sudo update-initramfs -u`.

### SSH lost after reboot

```bash
# From monitor/keyboard — flush all iptables rules immediately
sudo iptables -F
sudo iptables -P INPUT ACCEPT
```

Then re-add the SSH protection rules from Step 1 and re-save.

### DKMS module missing after kernel update

```bash
uname -r
dkms status
# If kernel version doesn't match:
sudo dpkg-reconfigure aic8800-usb-dkms
```

---

## Key Lessons (Hard Won)

| Mistake | Consequence | Fix |
|---|---|---|
| Using udev `RUN+=` with sleep for modeswitch | udev kills the process before firmware loads | Use a systemd oneshot service triggered by udev instead |
| Using `modprobe.d` quirks without `cmdline.txt` | `usb-storage` grabs device from initramfs before quirks apply | Add `usb-storage.quirks=1111:1111:i` to `cmdline.txt` |
| Not blacklisting `aic8800_fdrv` (without `_usb`) | Old module binds to device, correct `_usb` module never loads | Blacklist both old module names in `modprobe.d` |
| Starting hostapd/dnsmasq without waiting for switch | "unknown interface wlan0" — services fail and restart-loop | Add `After=` + `Requires=aic8800-switch.service` drop-ins |
| Using `dhcpcd.conf` on Bookworm | dhcpcd not installed — settings silently ignored | Use NetworkManager or set IP directly via `ip addr add` in service |
| Using 3-message modeswitch payload | Device re-enumerates but sometimes fails | Single-message payload `555342...f2` is reliable |
| Duplicate or multi-line `cmdline.txt` | Pi fails to boot or ignores parameters | Must be exactly one line |
| Running `sudo killall wpa_supplicant` | Can disrupt eth0 DHCP, drops SSH | Use NetworkManager `unmanaged-devices` instead |

## Complete File Reference

| File | Purpose |
|---|---|
| `/boot/firmware/cmdline.txt` | Kernel boot parameter — blocks usb-storage |
| `/etc/modprobe.d/aic8800-blacklist.conf` | Blacklists conflicting old modules |
| `/etc/udev/rules.d/99-aic8800-switch.rules` | Triggers switch service when device appears |
| `/etc/systemd/system/aic8800-switch.service` | Modeswitches dongle and loads drivers |
| `/etc/systemd/system/hostapd.service.d/wait-for-switch.conf` | Makes hostapd wait for dongle |
| `/etc/systemd/system/dnsmasq.service.d/wait-for-switch.conf` | Makes dnsmasq wait for dongle |
| `/etc/hostapd/hostapd.conf` | AP configuration |
| `/etc/default/hostapd` | Points hostapd to config file |
| `/etc/dnsmasq.d/travel-ap.conf` | DHCP server for AP clients |
| `/etc/NetworkManager/conf.d/99-aic-ap.conf` | Stops NetworkManager touching wlan0 |

## References

- [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) — DKMS driver packages (use these, not shenmintao)
- [radxa-pkg/aic8800 issue #68](https://github.com/radxa-pkg/aic8800/issues/68) — modeswitch payload discovery
- [linux.brostrend.com/advanced/usb_modeswitch](https://linux.brostrend.com/advanced/usb_modeswitch/) — AIC modeswitch reference

---

## Keywords

`aic8800d80` `aic8800` `usb-wifi-linux` `wifi6-usb-dongle` `raspberry-pi` `usb-modeswitch` `hostapd` `dnsmasq` `linux-driver` `dkms` `travel-router` `wifi-hotspot` `raspberry-pi-bookworm` `wlan0` `1111:1111` `a69c:8d81` `networkmanager` `iptables-nat` `usb-cd-rom-mode-fix` `aic8800_fdrv_usb` `radxa-pkg` `armv7l` `embedded-linux` `linux-wifi-fix` `usb-mass-storage-mode`
