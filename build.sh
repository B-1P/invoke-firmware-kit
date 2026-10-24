#!/bin/bash
# Build custom firmware for the Harman Kardon Invoke.
# Run from WSL (Ubuntu), Linux or macOS with Docker available. See README.md.
set -euo pipefail

OTA2_URL="https://harman.widen.net/s/jpssjqrsbl/harman-kardon-invoke-driver--ota2"
OTA2_ZIP_SHA256=f138fb1ea1175830181ca9e2f20509d3d991e709a52b9a970185b128314052cd
IMAGE=invoke-firmware-kit

usage() {
  cat <<EOF
Usage: ./build.sh [options]

  --ota-zip PATH        use an already-downloaded Harman OTA2 zip
  --airplay-name NAME   name shown in AirPlay pickers (default: Invoke)
  --wifi                ask for a Wi-Fi network to preset in the image
  --no-ssh              keep SSH (port 22) closed
  --control-bus         open Harman's message bus (ports 9998/9999) to your
                        network, for Home Assistant integrations. No password!
  --password-file PATH  read the root password from a file instead of asking
  --out DIR             output folder (default: ./out)
EOF
}

kit=$(cd "$(dirname "$0")" && pwd)
out="$kit/out"
zip=""
pwfile=""
pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ota-zip) zip=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --password-file) pwfile=$2; shift 2 ;;
    --airplay-name) pass+=("$1" "$2"); shift 2 ;;
    --wifi|--no-ssh|--control-bus) pass+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1"; usage; exit 2 ;;
  esac
done

command -v docker >/dev/null || {
  echo "Docker is required. On Windows, install Docker Desktop and enable WSL"
  echo "integration for your Ubuntu distro; on Linux, install docker.io."
  exit 1
}
docker info >/dev/null 2>&1 || { echo "Docker is installed but not running (or you lack permission)."; exit 1; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

if [ -z "$zip" ]; then
  zip="$kit/downloads/ota2.zip"
  if [ ! -f "$zip" ]; then
    echo ">> downloading Harman's OTA2 package (about 280 MB) from Harman's server"
    mkdir -p "$kit/downloads"
    curl -fL --retry 3 -o "$zip.part" "$OTA2_URL"
    mv "$zip.part" "$zip"
  fi
fi
[ -f "$zip" ] || { echo "OTA2 zip not found: $zip"; exit 1; }
zip=$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")
if [ "$(sha256 "$zip")" != "$OTA2_ZIP_SHA256" ]; then
  echo "note: the zip differs from the one this kit was tested with;"
  echo "      the build will still check the firmware image inside it."
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)

echo ">> preparing the build environment (first run downloads ~1 GB)"
docker build -q -t "$IMAGE" "$kit/docker" > /dev/null

run=(docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)"
     -v "$kit:/kit:ro" -v "$zip:/input/ota2.zip:ro" -v "$out:/out")
if [ -n "$pwfile" ]; then
  pwfile=$(cd "$(dirname "$pwfile")" && pwd)/$(basename "$pwfile")
  run+=(-v "$pwfile:/input/password:ro")
  pass+=(--password-file /input/password)
elif [ -t 0 ]; then
  run+=(-it)
else
  echo "No terminal for the password prompt; use --password-file."; exit 1
fi

"${run[@]}" "$IMAGE" bash /kit/docker/container-build.sh ${pass[@]+"${pass[@]}"}

echo
echo "Flash folder: $out/Invoke-flash"
if grep -qi microsoft /proc/version 2>/dev/null && command -v wslpath >/dev/null; then
  echo "In Windows:   $(wslpath -w "$out/Invoke-flash")"
fi
echo "Next: follow docs/FLASHING.md"
