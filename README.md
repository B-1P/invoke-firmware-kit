# Invoke firmware kit

Turn a Harman Kardon Invoke, the discontinued Cortana speaker, back into a
useful network speaker:

- **AirPlay** receiver, so it shows up in the AirPlay picker on iPhone, iPad,
  Mac and in apps like Spotify.
- **Wi-Fi** works again.
- **SSH** access as root, with a password you choose.
- A **boot hook** (`/data/boot.d/`) for your own scripts, changeable over SSH
  without reflashing.
- Bluetooth keeps working as before.

The kit modifies Harman's own final (OTA2) firmware. You build the image on
your own computer and flash it with Harman's official recovery procedure.

> **This repository contains only scripts and documentation.** No firmware and
> no compiled programs are included. During the build your computer downloads
> Harman's OTA2 package from Harman's server, Ubuntu 16.04 packages from
> Ubuntu, and the AirPlay receiver's source code from GitHub, then compiles
> everything locally. Please don't share the images you build; they contain
> Harman's firmware.

## Before you start

- **Risk:** flashing firmware can go wrong. Harman's flashing mode lives in the
  chip's boot ROM, so you can always reflash, including back to stock (see
  [Restoring stock firmware](#restoring-stock-firmware)), but there's no
  warranty. You do this at your own risk.
- **You need a Windows PC to flash.** Harman's flashing tool and USB driver are
  Windows-only.
- **To build**, you need Docker plus one of:
  - Windows 10/11 with **WSL 2** (Ubuntu) and **Docker Desktop** with WSL
    integration turned on (recommended for Windows users), or
  - Linux or macOS with Docker.
- About 3 GB of free disk space, and a USB data cable for the speaker.

## Build

These steps are for WSL; on Linux or macOS, skip step 1.

1. Install WSL and Ubuntu (`wsl --install` in an admin PowerShell, then
   reboot), and install Docker Desktop with *Settings → Resources → WSL
   integration* enabled for Ubuntu.
2. Open the **Ubuntu** terminal and clone this repository **into your Linux
   home folder** (not under `/mnt/c`):
   ```sh
   cd ~
   git clone https://github.com/B-1P/invoke-firmware-kit.git
   cd invoke-firmware-kit
   ```
3. Run the build:
   ```sh
   ./build.sh --wifi
   ```
   It downloads Harman's package (about 280 MB) and the build tools (about
   1 GB) on the first run, asks for a root password and your Wi-Fi details,
   then compiles and assembles the image. Expect 10–20 minutes the first time.

When it finishes, it prints the location of **`out/Invoke-flash`** (and the
Windows path to it when run in WSL). That folder is Harman's OTA2 package with
your custom firmware already in place.

### Build options

| Option | Effect |
|---|---|
| `--wifi` | Ask for a Wi-Fi network to preset in the image. Recommended: the speaker has no other way to join Wi-Fi yet. |
| `--airplay-name NAME` | Name shown in AirPlay pickers (default `Invoke`). |
| `--no-ssh` | Keep SSH closed. |
| `--control-bus` | Open Harman's internal message bus (ports 9998/9999) to your network, for Home Assistant experiments. It has **no authentication**, so only use it on a trusted network. |
| `--ota-zip PATH` | Use an OTA2 zip you already downloaded. |
| `--password-file PATH` | Read the root password from a file instead of prompting. |
| `--out DIR` | Output folder (default `out`). |

## Flash

Follow **[docs/FLASHING.md](docs/FLASHING.md)**. In short: install Harman's
USB driver once, put the speaker in flashing mode, run `run.bat` from the
`Invoke-flash\OTA2` folder, and type `l2nand 83` at the prompt.

## After flashing

- **Network:** the speaker joins the Wi-Fi you entered. Find its IP address
  in your router's list of devices; its hostname is `harman`. Reserving that
  address in your router's DHCP settings is a good idea.
- **AirPlay:** pick the name you chose (default **Invoke**) as the output on
  your phone or Mac.
- **SSH:**
  ```sh
  ssh -o HostKeyAlgorithms=+ssh-rsa root@<speaker-ip>
  ```
  Use the root password you chose. Key-based login doesn't work with the
  speaker's old SSH server; use the password.
- **Your own scripts:** create `/data/boot.d/`, put executable `*.sh` scripts
  in it, and they run at every boot (output goes to `<script>.log` next to
  each script). `/data` survives reboots; the rest of the system is
  read-only.

- **LED ring and buttons:** with `--control-bus`, other devices (e.g. Home
  Assistant) can play LED animations and receive tap, volume and button
  events. See [docs/CONTROL-BUS.md](docs/CONTROL-BUS.md).

- **Voice:** the microphones still work, but the Cortana wake word is
  gone. Findings and options are in [docs/VOICE.md](docs/VOICE.md).

## Known limitations

- AirPlay 1 only (not AirPlay 2 multi-room).
- No Wi-Fi setup screen yet: use `--wifi` at build time. To change networks
  later, rebuild with `--wifi` and reflash.
- SSH key login doesn't work; password login does.

## Restoring stock firmware

Harman's untouched package is in `downloads/ota2.zip` (or wherever you got
it). Extract it and flash it the same way as in docs/FLASHING.md. This puts
back Harman's final firmware.

## How it works

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Credits and licenses

- Community research by [coggy9/HKHacking](https://github.com/coggy9/HKHacking).
- AirPlay via [shairport-sync](https://github.com/mikebrady/shairport-sync) by
  Mike Brady and contributors.
- The kit's own scripts are under the MIT license (see `LICENSE`).
  Third-party components downloaded during the build are listed in
  [THIRD-PARTY.md](THIRD-PARTY.md).

Harman Kardon and Invoke are trademarks of their owners. This project is not
affiliated with or endorsed by Harman or Microsoft.
