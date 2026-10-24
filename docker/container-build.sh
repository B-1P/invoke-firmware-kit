#!/bin/bash
# Runs inside the build container. Started by ../build.sh; not meant to be
# run directly.
#
# Inputs:  /input/ota2.zip (Harman's OTA2 package), /kit (this repository)
# Output:  /out/Invoke-flash/ (ready-to-flash folder), /out/BUILD-INFO.txt
set -euo pipefail

STOCK_83_SHA256=b2e12178f98a0c0904cb1e6e2ba933de0c0fef8be7c24e7852bc9933294850e8

airplay_name="Invoke"
ssh=true
control_bus=false
wifi=false
password_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --airplay-name) airplay_name=$2; shift 2 ;;
    --no-ssh) ssh=false; shift ;;
    --control-bus) control_bus=true; shift ;;
    --wifi) wifi=true; shift ;;
    --password-file) password_file=$2; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

W=/work
rm -rf "$W"/{ota,rootfs,airplay} "$W"/*.squashfs "$W"/settings.json
mkdir -p "$W"

echo ">> unpacking Harman OTA2 package"
unzip -q /input/ota2.zip -d "$W/ota"
stock="$W/ota/OTA2/83_IMAGE"
[ -f "$stock" ] || { echo "OTA2/83_IMAGE not found in the zip"; exit 1; }
if [ "$(sha256sum "$stock" | cut -d' ' -f1)" != "$STOCK_83_SHA256" ]; then
  echo "OTA2/83_IMAGE does not match the known Harman final firmware."
  echo "This kit only patches that exact version; stopping."
  exit 1
fi

# Root password (needed for SSH; also protects the serial console login).
if [ -n "$password_file" ]; then
  password=$(head -n1 "$password_file")
else
  while true; do
    read -r -s -p "Choose a root password for the speaker: " password; echo
    read -r -s -p "Repeat it: " password2; echo
    [ "$password" = "$password2" ] && break
    echo "Passwords didn't match, try again."
  done
fi
[ ${#password} -ge 8 ] || { echo "Use at least 8 characters."; exit 1; }
root_hash=$(printf '%s' "$password" | python3 -c '
import crypt, sys
print(crypt.crypt(sys.stdin.read(), crypt.mksalt(crypt.METHOD_SHA512)))')
unset password password2

wifi_json=""
if $wifi; then
  read -r -p "Wi-Fi network name: " ssid
  read -r -s -p "Wi-Fi password: " wifipass; echo
  wifi_json=$(SSID="$ssid" PASS="$wifipass" python3 -c '
import hashlib, json, os
ssid, pw = os.environ["SSID"], os.environ["PASS"]
if not (1 <= len(ssid.encode()) <= 32): raise SystemExit("network name must be 1-32 bytes")
if not (8 <= len(pw) <= 63): raise SystemExit("WPA password must be 8-63 characters")
psk = hashlib.pbkdf2_hmac("sha1", pw.encode(), ssid.encode(), 4096, 32).hex()
print(json.dumps({"wifi_ssid_hex": ssid.encode().hex(), "wifi_psk_hex": psk}))')
  unset wifipass
fi

ROOT_HASH="$root_hash" NAME="$airplay_name" SSH=$ssh BUS=$control_bus WIFI="$wifi_json" \
python3 -c '
import json, os
s = {"root_hash": os.environ["ROOT_HASH"], "airplay_name": os.environ["NAME"],
     "ssh": os.environ["SSH"] == "true", "control_bus": os.environ["BUS"] == "true"}
if os.environ["WIFI"]:
    s.update(json.loads(os.environ["WIFI"]))
json.dump(s, open("/work/settings.json", "w"))'
chmod 600 "$W/settings.json"

bash /kit/scripts/build_airplay.sh "$W/airplay"

echo ">> extracting the root filesystem"
python3 /kit/scripts/pack_image.py extract-rootfs "$stock" "$W/stock.squashfs"
unsquashfs -n -d "$W/rootfs" "$W/stock.squashfs" > /dev/null

echo ">> applying changes"
python3 /kit/scripts/patch_rootfs.py "$W/rootfs" "$W/airplay" /kit/overlay "$W/settings.json"
rm -f "$W/settings.json"

echo ">> repacking"
mksquashfs "$W/rootfs" "$W/new.squashfs" -comp gzip -b 131072 -noappend -no-progress > /dev/null
python3 /kit/scripts/pack_image.py build "$stock" "$W/new.squashfs" "$W/83_IMAGE.new"

echo ">> assembling the flash folder"
rm -rf /out/Invoke-flash
cp -r "$W/ota" /out/Invoke-flash
cp "$W/83_IMAGE.new" /out/Invoke-flash/OTA2/83_IMAGE
{
  echo "Invoke firmware kit build"
  echo "date:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "airplay name: $airplay_name"
  echo "ssh:          $ssh"
  echo "control bus:  $control_bus"
  echo "wifi preset:  $wifi"
  echo "83_IMAGE sha256: $(sha256sum "$W/83_IMAGE.new" | cut -d' ' -f1)"
} > /out/BUILD-INFO.txt

if [ -n "${HOST_UID:-}" ]; then
  chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" /out/Invoke-flash /out/BUILD-INFO.txt 2>/dev/null || true
fi
echo ">> done"
