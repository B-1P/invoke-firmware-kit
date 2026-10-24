#!/bin/sh
# Makes AirPlay a source of Harman's music-source-manager, like Bluetooth:
# - when AirPlay starts playing, it becomes the active source, so Bluetooth
#   playback stops (and the other way round);
# - a tap on the top (com.harman.music.pause/stop) ends the AirPlay session;
# - play state is reported, so the speaker's own UI knows what's playing.
#
# This shairport-sync build can't ask the phone to pause (that needs
# DACP), so "pause" disconnects AirPlay; the phone shows it as stopped.
#
#   airplay-source.sh daemon    started by airplay-run.sh
#   airplay-source.sh playing   shairport-sync: run_this_before_play_begins
#   airplay-source.sh stopped   shairport-sync: run_this_after_play_ends

# shairport-sync passes on its private library path; the bus tool needs
# the speaker's own libraries.
unset LD_LIBRARY_PATH
URI=com.harman.airplay
WAMP=/usr/bin/test-wamp-client

args() {  # pos_arg [named-args-json]
    named=${2:-'{}'}
    printf '{"pos_args":["%s"],"nam_args":%s}' "$1" "$named"
}

call() {  # procedure json
    out=$("$WAMP" -c "$1" -a "$2" 2>&1) || return 1
    case $out in *"Error:"*) return 1 ;; esac
}

state() {  # playing|stopped
    call com.harman.source.nowPlayingUpdate \
        "$(args "$URI" "{\"state\":\"$1\",\"service\":\"airplay\"}")"
}

end_session() {
    # The session ends when the receiver exits; airplay-run.sh restarts it.
    pid=$(pidof shairport-sync) && kill $pid
    state stopped
}

# Serve one procedure forever; test-wamp-client exits after each call.
serve() {  # action
    while true; do
        if "$WAMP" -p "$URI.$1" -a '{"pos_args":[],"nam_args":{}}' -m 1 > /dev/null 2>&1; then
            case $1 in stop|pause) end_session ;; esac
        else
            sleep 5   # bus not up yet
        fi
    done
}

case $1 in
daemon)
    until call com.harman.source.register "$(args "$URI")"; do sleep 5; done
    for action in stop pause resume next prev; do
        serve $action &
    done
    wait ;;
playing)
    call com.harman.source.start "$(args "$URI")"
    state playing ;;
stopped)
    state stopped ;;
*)
    echo "usage: $0 daemon|playing|stopped" >&2
    exit 2 ;;
esac
