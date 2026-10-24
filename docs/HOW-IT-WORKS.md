# How it works

## The speaker

The Invoke (Harman's codename *Podium*) runs embedded Linux 3.8 on a Marvell
BG2CDP (ARM Cortex-A7, hard-float, glibc 2.23). Harman's final OTA2 update
(August 2021) removed Cortana and turned off Wi-Fi, leaving a Bluetooth
speaker.

## Harman's firmware package

`OTA2/83_IMAGE` is a container: a header with a partition table, followed by
each partition's data. Each table entry has the partition's name, the length
of its data in the file, a CRC32 of that data, and where it goes on the NAND.
The `l2nand 83` command checks every CRC before writing.

The `rootfs` partition holds a gzip squashfs image (the read-only system),
followed by a few padding bytes.

## What the build does

1. Checks that `83_IMAGE` is exactly Harman's final firmware (SHA-256).
2. Compiles shairport-sync for the speaker from a pinned upstream commit, in
   an Ubuntu 16.04 container whose compiler and libraries match the speaker.
3. Extracts the root filesystem, applies the changes below, and repacks it
   with the same squashfs settings.
4. Puts the new filesystem back into the container and updates the rootfs
   partition's length and CRC; all other partitions are unchanged. Every CRC
   is re-checked.

Extraction and repacking happen inside the container's own (case-sensitive)
filesystem. That matters: the firmware contains file names that differ only
by case, which a Windows or default macOS disk would merge.

## Changes to the system

| File | Change |
|---|---|
| `etc/podium/podium.conf` | Don't start the `wifi-blocker` service. |
| `init.rc` | Start the AirPlay service, the boot hook and Wi-Fi onboarding after Harman's app. With `--no-ssh`, don't start the SSH server. |
| `usr/sbin/firewall.sh` | Allow AirPlay (TCP 5000, UDP 6001–6010); allow SSH unless `--no-ssh`; with `--control-bus`, allow ports 9998/9999. |
| `etc/shadow` | Root password (SHA-512 hash of the one you chose). |
| `usr/bin/shairport-sync`, `usr/lib/airplay/` | The AirPlay receiver and its private copies of OpenSSL, libconfig and popt. |
| `usr/bin/airplay-run.sh` | Pipes the receiver's audio into the speaker's own `aplay`, on the stock `music` output, so it mixes with other sounds. |
| `etc/shairport-sync.conf` | AirPlay name and ports. |
| `usr/bin/data-hooks.sh` | Runs `/data/boot.d/*.sh` at boot. |
| `usr/share/onboarding/`, `usr/bin/onboarding` | Wi-Fi onboarding: if Wi-Fi doesn't come up, opens the `Invoke-Setup-XXXX` network (hostapd on `p2p0`, dnsmasq) with a setup page (Python). Uses only programs already in the firmware. See WIFI-SETUP.md. |
| `sbin/wpa_supplicant_setup.sh` | At boot, use the network saved through the setup page (`/data/onboarding/wpa_supplicant.conf`) when there is one. |
| `etc/wpa_supplicant.conf.in`, `system/etc/wpa_supplicant.conf.in` | With `--wifi`, your network (the password is stored as a derived WPA key). The speaker copies this file into place at every boot. |

## Why AirPlay is wired this way

- The speaker's OpenSSL has the same file name as Ubuntu's but lacks its
  symbol versions, so the receiver gets private copies in `/usr/lib/airplay`.
- shairport-sync's ALSA output couldn't negotiate a format with Harman's audio
  chain, while the speaker's own `aplay` plays to it fine. So the receiver
  writes raw audio to stdout and `aplay` plays it.
