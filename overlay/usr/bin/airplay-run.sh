#!/bin/sh
# AirPlay receiver: shairport-sync decodes the stream to raw 16-bit 44.1 kHz
# stereo on stdout, and aplay plays it through the speaker's stock "music"
# ALSA chain (software volume -> mixer -> DSP), so it mixes with Bluetooth
# and system sounds. The receiver's own libraries live in /usr/lib/airplay.
# /system/lib has the speaker's mDNS client library, used to announce AirPlay.
export LD_LIBRARY_PATH=/usr/lib/airplay:/system/lib
# Register AirPlay with Harman's music-source-manager (see airplay-source.sh).
/bin/sh /usr/bin/airplay-source.sh daemon &
while true; do
  /usr/bin/shairport-sync -c /etc/shairport-sync.conf -o stdout \
    | aplay -q -D music -f S16_LE -r 44100 -c 2 -t raw -
  sleep 2
done
