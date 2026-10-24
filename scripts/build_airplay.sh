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

# AirPlay is announced through the speaker's own mDNS daemon (mdnsd, via
# its /system/lib/libmdnssd.so), which answers phones' first lookups
# directly; shairport-sync's built-in announcer only multicasts, which
# some Wi-Fi networks don't pass on. To link without Harman's library,
# build a placeholder with the same name; the real one is used on the
# speaker. The header comes from Avahi's copy of Apple's dns_sd API.
stub=/work/dnssd-stub
mkdir -p "$stub"
cat > "$stub/stub.c" <<'STUB'
#include <dns_sd.h>
void DNSServiceRefDeallocate(DNSServiceRef r) { (void)r; }
DNSServiceErrorType DNSServiceRegister(DNSServiceRef *r, DNSServiceFlags f, uint32_t i,
    const char *n, const char *t, const char *d, const char *h, uint16_t p, uint16_t l,
    const void *x, DNSServiceRegisterReply c, void *ctx) { return kDNSServiceErr_Unknown; }
DNSServiceErrorType DNSServiceUpdateRecord(DNSServiceRef r, DNSRecordRef rr,
    DNSServiceFlags f, uint16_t l, const void *d, uint32_t t) { return kDNSServiceErr_Unknown; }
STUB
arm-linux-gnueabihf-gcc -shared -fPIC -I/usr/include/avahi-compat-libdns_sd \
  -Wl,-soname,libmdnssd.so -o "$stub/libdns_sd.so" "$stub/stub.c"

echo ">> building shairport-sync for ARM (this takes a few minutes)"
cd "$src"
autoreconf -fi >/dev/null 2>&1
export PKG_CONFIG_PATH=/usr/lib/arm-linux-gnueabihf/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig
# stdout backend: audio is piped into the speaker's own aplay, which plays
# through Harman's mixer.
# Hammerton decoder: ALAC without FFmpeg. dns_sd is tried first,
# tinysvcmdns is the fallback if mdnsd isn't running.
./configure --host=arm-linux-gnueabihf CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ \
  CPPFLAGS=-I/usr/include/avahi-compat-libdns_sd LDFLAGS=-L"$stub" \
  --with-stdout --with-ssl=openssl --with-dns_sd --with-tinysvcmdns --with-hammerton \
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
