#!/bin/bash
# Build shairport-sync (AirPlay 1 receiver) for the speaker from upstream
# source, and collect the ARM runtime libraries it needs from Ubuntu's
# packages. Runs inside the build container.
#
# Usage: build_airplay.sh <output-dir>
#   <output-dir>/shairport-sync   the receiver
#   <output-dir>/lib/             libraries it loads at runtime
set -euo pipefail

SHAIRPORT_REPO=https://github.com/mikebrady/shairport-sync.git
# Pinned so everyone builds the same, tested receiver.
SHAIRPORT_COMMIT=cf6998daa1876c5a8f97128a960c8afc0e731841

out=$1
src=/work/shairport-sync
mkdir -p "$out/lib"

echo ">> fetching shairport-sync ${SHAIRPORT_COMMIT:0:7}"
rm -rf "$src"
git init -q "$src"
git -C "$src" remote add origin "$SHAIRPORT_REPO"
git -C "$src" fetch -q --depth 1 origin "$SHAIRPORT_COMMIT"
git -C "$src" checkout -q FETCH_HEAD

echo ">> building shairport-sync for ARM (this takes a few minutes)"
cd "$src"
autoreconf -fi >/dev/null 2>&1
export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig
# stdout backend: audio is piped into the speaker's own aplay, which plays
# through Harman's mixer. tinysvcmdns: built-in AirPlay discovery.
# Hammerton decoder: ALAC without FFmpeg.
./configure --host=arm-linux-gnueabihf CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ \
  --with-stdout --with-ssl=openssl --with-tinysvcmdns --with-hammerton \
  --without-ffmpeg --sysconfdir=/etc > /work/shairport-configure.log 2>&1 \
  || { tail -30 /work/shairport-configure.log; exit 1; }
# GCC 4.9 defaults to C90, and Ubuntu 16.04 has OpenSSL 1.0.2, which lacks
# the EVP_MD_CTX_new/free names used upstream.
make CFLAGS='-std=gnu11 -O2 -DEVP_MD_CTX_new=EVP_MD_CTX_create -DEVP_MD_CTX_free=EVP_MD_CTX_destroy' \
  -j"$(nproc)" > /work/shairport-build.log 2>&1 \
  || { grep -E 'error' /work/shairport-build.log | head -20; exit 1; }
arm-linux-gnueabihf-strip -o "$out/shairport-sync" shairport-sync

echo ">> collecting runtime libraries"
# The speaker's own OpenSSL lacks the symbol versions this build expects, so
# the receiver gets private copies, loaded via LD_LIBRARY_PATH.
for lib in libcrypto.so.1.0.0 libssl.so.1.0.0 libconfig.so.9 libpopt.so.0; do
  path=$(find /lib/arm-linux-gnueabihf /usr/lib/arm-linux-gnueabihf -name "$lib" | head -1)
  [ -n "$path" ] || { echo "missing $lib"; exit 1; }
  cp -L "$path" "$out/lib/$lib"
done
ls -la "$out" "$out/lib"
