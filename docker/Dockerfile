# Build environment for the Invoke firmware kit.
#
# Ubuntu 16.04 is used on purpose: the speaker runs glibc 2.23, and this
# release ships a matching ARM hard-float cross compiler (GCC 4.9) and the
# ARM libraries that AirPlay needs. Nothing here is shipped with the kit;
# every package is downloaded from Ubuntu's archive when you build.
FROM ubuntu:16.04

RUN dpkg --add-architecture armhf \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        gcc-4.9-arm-linux-gnueabihf \
        g++-4.9-arm-linux-gnueabihf \
        binutils-arm-linux-gnueabihf \
        build-essential autoconf automake libtool pkg-config \
        git ca-certificates \
        squashfs-tools unzip python3 dropbear-bin \
        libssl-dev:armhf libpopt-dev:armhf libconfig-dev:armhf \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf arm-linux-gnueabihf-gcc-4.9 /usr/bin/arm-linux-gnueabihf-gcc \
    && ln -sf arm-linux-gnueabihf-g++-4.9 /usr/bin/arm-linux-gnueabihf-g++

WORKDIR /work
