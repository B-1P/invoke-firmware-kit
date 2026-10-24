#!/bin/sh
# Wi-Fi onboarding (captive-portal setup) for the Harman Kardon Invoke
# ("Podium") running custom firmware.
#
# If the speaker has no working Wi-Fi at boot it opens its own open network
# "Invoke-Setup-XXXX" with a small web page where you pick your home network
# and type its password. The speaker then joins that network, saves the
# credentials in /data/onboarding/ (which survives reboots) and closes the
# setup network. If joining fails, the setup network comes back.
#
# Usage: onboarding <command>
#   status                 show what is going on
#   start                  open the setup network now (even if Wi-Fi works)
#   stop                   close the setup network, go back to normal Wi-Fi
#   join SSID [PASSWORD]   join a network from the command line (no portal)
#   forget                 delete the Wi-Fi saved by onboarding
#   force-next-boot        open the setup network at the next boot
#   scan                   list nearby networks
#   log                    show the log
#   boot                   (used by init at startup)
#
# Written for busybox/bash /bin/sh. Needs: wpa_supplicant + wpa_cli, hostapd,
# dnsmasq, python 2.7 (all already in the stock Invoke firmware).

PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/system/usr/bin:/system/bin:/system/sbin:$PATH
export PATH
umask 077     # runtime files may contain keys; hostapd's directory is opened up explicitly

SELF=$(readlink -f "$0" 2>/dev/null) || SELF=$0
[ -n "$SELF" ] || SELF=$0
APP_DIR=${ONB_APP_DIR:-$(dirname "$SELF")}

# ---- configuration -----------------------------------------------------------
# Built-in fallbacks (onboarding.conf next to this script normally sets all).
AP_SSID_PREFIX=Invoke-Setup; AP_PASSPHRASE=; AP_CHANNEL=6
AP_IP=192.168.4.1; AP_NETMASK=255.255.255.0
AP_DHCP_START=192.168.4.10; AP_DHCP_END=192.168.4.60
WIFI_COUNTRY=
BOOT_TIMEOUT=60; JOIN_TIMEOUT=45; DHCP_TIMEOUT=30
RETRY_INTERVAL=300; RETRY_WINDOW=45; FORCE_TIMEOUT=900; LOST_TIMEOUT=0
RAPID_BOOTS=3; RAPID_WINDOW=90
STATE_DIR=/data/onboarding; RUN_DIR=/tmp/onboarding
STA_IFACE=wlan0; AP_IFACE=p2p0
WIFI_CONF=/data/wifi/wpa_supplicant.conf
WIFI_CONF_IN=/system/etc/wpa_supplicant.conf.in
WPA_CTRL=/data/wifi; PORTAL_PORT=80
# Programs (overridable, mainly for the test harness)
WPA_CLI=wpa_cli; HOSTAPD=hostapd; HOSTAPD_CLI=hostapd_cli; DNSMASQ=/usr/bin/dnsmasq
PYTHON=python; IPTABLES=iptables; IFCONFIG=ifconfig; SETPROP=setprop
DHCPCD=/system/bin/dhcpcd; SYS_NET=/sys/class/net; UPTIME_FILE=/proc/uptime
LOGCAT=logcat; SLEEP=sleep
# How long to wait for hostapd to report state=ENABLED on one channel.
AP_START_TIMEOUT=8

[ -f "$APP_DIR/onboarding.conf" ] && . "$APP_DIR/onboarding.conf"
# Per-speaker overrides live on the writable partition.
[ -f "${STATE_DIR}/onboarding.conf" ] && . "${STATE_DIR}/onboarding.conf"
# Extra override file (used by tests).
[ -n "$ONB_CONF" ] && [ -f "$ONB_CONF" ] && . "$ONB_CONF"

SAVED_CONF=$STATE_DIR/wpa_supplicant.conf     # the persistent credentials
SAVED_LABEL=$STATE_DIR/saved_ssid.txt         # human readable name of it
# The log is kept on /data by default so it survives an unplug (LOG_DIR).
LOG=${LOG_DIR:-$STATE_DIR}/onboarding.log
# hostapd drops root privileges (to user "wifi") before it reads its config
# and creates its control socket, so it gets a directory it can use.
AP_DIR=$RUN_DIR/ap
HOSTAPD_CONF=$AP_DIR/hostapd.conf
HOSTAPD_CTRL=$AP_DIR/ctrl
LOOP_PID=$RUN_DIR/loop.pid

# ---- helpers -------------------------------------------------------------------
now() { read -r up _ < "$UPTIME_FILE"; echo "${up%%.*}"; }

log() {
    [ -d "$RUN_DIR" ] || { mkdir -p "$RUN_DIR" && chmod 0711 "$RUN_DIR"; } 2>/dev/null
    mkdir -p "${LOG%/*}" 2>/dev/null
    # keep the log small (it lives on flash by default)
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ]; then
        tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$$] $*" >> "$LOG"
    [ -n "$ONB_QUIET" ] || echo "onboarding: $*" >&2
}

wpa() { "$WPA_CLI" -p "$WPA_CTRL" -i "$STA_IFACE" "$@" 2>/dev/null; }
wpa_state() { wpa status | sed -n 's/^wpa_state=//p'; }
sta_ip() { "$IFCONFIG" "$STA_IFACE" 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'; }
network_count() { wpa list_networks | tail -n +2 | grep -c .; }

is_connected() {
    [ "$(wpa_state)" = COMPLETED ] || return 1
    ip=$(sta_ip)
    case "$ip" in ''|0.0.0.0|169.254.*) return 1 ;; esac
    return 0
}

wait_wpa() {    # wait until wpa_supplicant answers on its control socket
    t=0
    while [ "$t" -lt "$1" ]; do
        [ "$(wpa ping)" = PONG ] && return 0
        $SLEEP 1; t=$((t + 1))
    done
    return 1
}

wait_connected() {
    t=0
    while [ "$t" -lt "$1" ]; do
        is_connected && return 0
        $SLEEP 2; t=$((t + 2))
    done
    return 1
}

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
pidfile_alive() { [ -f "$1" ] && pid_alive "$(cat "$1" 2>/dev/null)"; }

kill_pidfile() {
    [ -f "$1" ] || return 0
    p=$(cat "$1" 2>/dev/null)
    if pid_alive "$p"; then
        kill "$p" 2>/dev/null
        i=0
        while pid_alive "$p" && [ "$i" -lt 6 ]; do $SLEEP 1; i=$((i + 1)); done
        pid_alive "$p" && kill -9 "$p" 2>/dev/null
    fi
    rm -f "$1"
}

valid_conf() {  # a usable wpa_supplicant.conf with at least one network
    [ -s "$1" ] && grep -q '^ctrl_interface=' "$1" && grep -q '^network={' "$1"
}

ap_ssid() {
    mac=$(cat "$SYS_NET/$STA_IFACE/address" 2>/dev/null | tr -d ':\n' | tr 'abcdef' 'ABCDEF')
    [ -n "$mac" ] || mac=0000
    echo "${AP_SSID_PREFIX}-${mac#${mac%????}}"
}

# Write $2 (contents of file $1) to the live wpa_supplicant config and reload.
apply_wifi_conf() {
    cat "$1" > "$WIFI_CONF.onb" && mv "$WIFI_CONF.onb" "$WIFI_CONF"
    chmod 0600 "$WIFI_CONF" 2>/dev/null
    chown wifi "$WIFI_CONF" 2>/dev/null
    wpa reconfigure > /dev/null
}

# Copy credentials saved by onboarding over the per-boot default config.
# (The firmware rewrites $WIFI_CONF from $WIFI_CONF_IN on every boot.)
restore_saved() {
    valid_conf "$SAVED_CONF" || return 0
    if cmp -s "$SAVED_CONF" "$WIFI_CONF"; then
        log "saved Wi-Fi already active"
    else
        log "restoring saved Wi-Fi ($(cat "$SAVED_LABEL" 2>/dev/null))"
        apply_wifi_conf "$SAVED_CONF"
    fi
}

save_conf() {   # make $1 the persistent credentials
    mkdir -p "$STATE_DIR"
    cat "$1" > "$SAVED_CONF.tmp" && chmod 0600 "$SAVED_CONF.tmp" && sync &&
        mv "$SAVED_CONF.tmp" "$SAVED_CONF" && sync
    [ -n "$2" ] && { printf '%s\n' "$2" > "$SAVED_LABEL"; sync; }
}

dhcp_kick() {   # make sure the station interface asks the new router for an IP
    if pidof dhcpcd > /dev/null 2>&1; then
        log "dhcp: asking running dhcpcd to rebind $STA_IFACE"
        "$DHCPCD" -n "$STA_IFACE" > /dev/null 2>&1
    else
        log "dhcp: starting dhcpcd_wlan0"
        "$SETPROP" ctl.start "dhcpcd_${STA_IFACE}:-f /system/etc/dhcpcd/dhcpcd.conf $STA_IFACE"
    fi
}

dhcp_restart() {
    log "dhcp: restarting dhcpcd_${STA_IFACE}"
    "$SETPROP" ctl.stop "dhcpcd_${STA_IFACE}"
    $SLEEP 1
    "$SETPROP" ctl.start "dhcpcd_${STA_IFACE}:-f /system/etc/dhcpcd/dhcpcd.conf $STA_IFACE"
}

# Wait for the station to join. Sets JOIN_RESULT to one of:
#   ok, wrong_key, assoc_failed, not_found, no_ip
wait_join() {
    limit=$1; t=0; saw_auth=0; saw_hs=0; done_at=; kicked=0
    while :; do
        st=$(wpa_state)
        case "$st" in
            4WAY_HANDSHAKE|GROUP_HANDSHAKE) saw_hs=1; saw_auth=1 ;;
            AUTHENTICATING|ASSOCIATING|ASSOCIATED) saw_auth=1 ;;
        esac
        if [ "$st" = COMPLETED ]; then
            [ -n "$done_at" ] || { done_at=$t; log "associated after ${t}s, waiting for IP"; }
            if is_connected; then JOIN_RESULT=ok; return 0; fi
            el=$((t - done_at))
            [ "$el" -ge 8 ] && [ "$kicked" = 0 ] && { dhcp_kick; kicked=1; }
            [ "$el" -ge 18 ] && [ "$kicked" = 1 ] && { dhcp_restart; kicked=2; }
            [ "$el" -ge "$DHCP_TIMEOUT" ] && { JOIN_RESULT=no_ip; return 1; }
        else
            done_at=
            # wpa_supplicant marks a network TEMP-DISABLED after repeated failures
            if wpa list_networks | grep -q 'TEMP-DISABLED'; then
                if [ "$saw_hs" = 1 ]; then JOIN_RESULT=wrong_key; else JOIN_RESULT=assoc_failed; fi
                return 1
            fi
            if [ "$t" -ge "$limit" ]; then
                if [ "$saw_hs" = 1 ]; then JOIN_RESULT=wrong_key
                elif [ "$saw_auth" = 1 ]; then JOIN_RESULT=assoc_failed
                else JOIN_RESULT=not_found; fi
                return 1
            fi
        fi
        $SLEEP 1; t=$((t + 1))
    done
}

# Try the networks in config file $1 (AP must be down). Returns 0 on success.
try_conf() {
    "$IFCONFIG" "$STA_IFACE" 0.0.0.0 2>/dev/null   # drop any stale address
    apply_wifi_conf "$1"
    wpa enable_network all > /dev/null
    wpa reconnect > /dev/null
    wait_join "$2"
}

set_result() {  # remembered for the portal: <code> <ssid label>
    printf '%s\n%s\n' "$1" "$2" > "$RUN_DIR/last_result"
}

# ---- firewall ----------------------------------------------------------------------
# Only what setup needs is opened on the setup network: DHCP, DNS and the
# portal. HTTPS is refused straight away so phones' captive-portal checks
# don't wait for a timeout. Everything else (ADB, Libre's services) stays
# closed on this password-less network.
fw_rules() {
    printf '%s\n' "-p udp --dport 67 -j ACCEPT" "-p udp --dport 53 -j ACCEPT" \
        "-p tcp --dport 53 -j ACCEPT" "-p tcp --dport $PORTAL_PORT -j ACCEPT" \
        "-p tcp --dport 443 -j REJECT --reject-with tcp-reset"
}
fw_open() {
    command -v "$IPTABLES" > /dev/null 2>&1 || return 0
    fw_rules | while read -r rule; do
        # shellcheck disable=SC2086
        "$IPTABLES" -C INPUT -i "$AP_IFACE" $rule 2>/dev/null ||
            "$IPTABLES" -I INPUT -i "$AP_IFACE" $rule 2>/dev/null
    done
}
fw_close() {
    command -v "$IPTABLES" > /dev/null 2>&1 || return 0
    fw_rules | while read -r rule; do
        # shellcheck disable=SC2086
        while "$IPTABLES" -D INPUT -i "$AP_IFACE" $rule 2>/dev/null; do :; done
    done
    # rule used by earlier versions: everything on the setup network
    while "$IPTABLES" -D INPUT -i "$AP_IFACE" -j ACCEPT 2>/dev/null; do :; done
}

# ---- access point ----------------------------------------------------------------
# freq (MHz) -> "channel hw_mode", empty if unknown
freq_to_chan() {
    f=$1
    case "$f" in ''|*[!0-9]*) return ;; esac
    if [ "$f" -eq 2484 ]; then echo "14 g"
    elif [ "$f" -ge 2412 ] && [ "$f" -le 2472 ]; then echo "$(( (f - 2407) / 5 )) g"
    elif [ "$f" -ge 4910 ] && [ "$f" -le 5980 ]; then echo "$(( (f - 5000) / 5 )) a"
    fi
}

sta_assoc_freq() {      # frequency of the station's current association, if any
    wpa status | awk -F= '$1=="wpa_state"{s=$2} $1=="freq"{f=$2} END{if(s=="COMPLETED")print f}'
}

prepare_ap_dir() {
    [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR"
    chmod 0711 "$RUN_DIR"
    mkdir -p "$AP_DIR"
    if chown wifi:wifi "$AP_DIR" 2>/dev/null; then chmod 0770 "$AP_DIR"
    else chmod 0777 "$AP_DIR"; fi
    # hostapd creates (and on exit removes) its control directory itself;
    # clear a stale one left by a killed hostapd
    if [ -d "$HOSTAPD_CTRL" ]; then
        rm -f "$HOSTAPD_CTRL/$AP_IFACE"
        rmdir "$HOSTAPD_CTRL" 2>/dev/null
    fi
}

write_hostapd_conf() {  # ssid channel hw_mode
    cat > "$HOSTAPD_CONF" <<EOF
interface=$AP_IFACE
driver=nl80211
ctrl_interface=$HOSTAPD_CTRL
ssid=$1
hw_mode=${3:-g}
channel=$2
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
max_num_sta=8
ap_isolate=1
EOF
    if [ -n "$AP_PASSPHRASE" ]; then
        cat >> "$HOSTAPD_CONF" <<EOF
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$AP_PASSPHRASE
EOF
    fi
    if chown root:wifi "$HOSTAPD_CONF" 2>/dev/null; then chmod 0640 "$HOSTAPD_CONF"
    else chmod 0644 "$HOSTAPD_CONF"; fi
}

hostapd_state() {
    "$HOSTAPD_CLI" -p "$HOSTAPD_CTRL" -i "$AP_IFACE" status 2>/dev/null | sed -n 's/^state=//p'
}

hostapd_diag() {        # hostapd logs to logcat, not stdout: copy its lines
    "$LOGCAT" -d 2>/dev/null | grep -E "hostapd *\( *$1\)" | tail -n 12 |
        while IFS= read -r l; do log "  logcat: $l"; done
}

# Start hostapd on one channel; 0 when it reports ENABLED.
start_hostapd() {       # ssid channel hw_mode
    write_hostapd_conf "$1" "$2" "$3"
    log "starting setup network '$1' on $AP_IFACE channel $2 (802.11$3)"
    "$HOSTAPD" "$HOSTAPD_CONF" < /dev/null >> "$LOG" 2>&1 &
    hp=$!
    echo "$hp" > "$RUN_DIR/hostapd.pid"
    i=0; st=
    while [ "$i" -lt "$AP_START_TIMEOUT" ]; do
        $SLEEP 1; i=$((i + 1))
        if ! pid_alive "$hp"; then st=exited; break; fi
        st=$(hostapd_state)
        [ "$st" = ENABLED ] && { echo "$2 $3" > "$RUN_DIR/ap_channel"; return 0; }
    done
    log "hostapd did not come up on channel $2 (${st:-no answer on $HOSTAPD_CTRL})"
    hostapd_diag "$hp"
    kill_pidfile "$RUN_DIR/hostapd.pid"
    return 1
}

foreign_hostapd() {     # hostapd processes that are not ours
    mine=$(cat "$RUN_DIR/hostapd.pid" 2>/dev/null)
    for p in $(pidof hostapd 2>/dev/null); do [ "$p" = "$mine" ] || echo "$p"; done
}

# Bring the AP up. The radio serves one channel at a time: if the station is
# associated, the AP must use the station's channel. Otherwise AP_CHANNEL
# (then 1/6/11) is used.
ap_up() {
    ssid=$(ap_ssid)
    others=$(foreign_hostapd)
    if [ -n "$others" ]; then
        log "another hostapd is running ($others), stopping it"
        "$SETPROP" ctl.stop hostapd 2>/dev/null
        kill $others 2>/dev/null; $SLEEP 1
    fi
    kill_pidfile "$RUN_DIR/hostapd.pid"
    prepare_ap_dir
    rm -f "$RUN_DIR/ap_channel"

    up=0
    sf=$(sta_assoc_freq)
    if [ -n "$sf" ]; then
        set -- $(freq_to_chan "$sf")
        if [ -n "$1" ]; then
            log "station is associated at $sf MHz, using its channel $1"
            start_hostapd "$ssid" "$1" "$2" && up=1
        fi
        if [ "$up" = 0 ]; then
            log "cannot share the station's channel; disconnecting the station"
            wpa disconnect > /dev/null
            $SLEEP 1
        fi
    fi
    if [ "$up" = 0 ]; then
        tried=
        for c in "$AP_CHANNEL" 1 6 11; do
            case " $tried " in *" $c "*) continue ;; esac
            tried="$tried $c"
            start_hostapd "$ssid" "$c" g && { up=1; break; }
        done
    fi
    if [ "$up" = 0 ]; then
        log "ERROR: could not start the setup network on any channel (see logcat lines above)"
        return 1
    fi

    "$IFCONFIG" "$AP_IFACE" "$AP_IP" netmask "$AP_NETMASK" up
    fw_open

    kill_pidfile "$RUN_DIR/dnsmasq.pid"
    write_dnsmasq_conf
    : > "$RUN_DIR/dnsmasq.leases"
    "$DNSMASQ" -C "$RUN_DIR/dnsmasq.conf" -x "$RUN_DIR/dnsmasq.pid" >> "$LOG" 2>&1 ||
        log "ERROR: dnsmasq failed to start"

    start_portal "$ssid"
    echo "$ssid" > "$RUN_DIR/ap_up"
    log "setup network '$ssid' is up on channel $(cut -d' ' -f1 "$RUN_DIR/ap_channel")"
    return 0
}

write_dnsmasq_conf() {
    cat > "$RUN_DIR/dnsmasq.conf" <<EOF
# DHCP + "answer every name with the portal" DNS for the setup network only.
interface=$AP_IFACE
except-interface=lo
bind-interfaces
user=root
group=root
no-resolv
no-hosts
no-poll
address=/#/$AP_IP
dhcp-range=$AP_DHCP_START,$AP_DHCP_END,$AP_NETMASK,5m
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
dhcp-option=114,"http://$AP_IP/"
dhcp-authoritative
dhcp-leasefile=$RUN_DIR/dnsmasq.leases
EOF
}

start_portal() {
    kill_pidfile "$RUN_DIR/portal.pid"
    ONB_RUN_DIR=$RUN_DIR ONB_STATE_DIR=$STATE_DIR ONB_APP_DIR=$APP_DIR \
    ONB_AP_SSID=$1 ONB_AP_IP=$AP_IP ONB_ADDR=$AP_IP ONB_PORT=$PORTAL_PORT \
    ONB_WPA_CLI=$WPA_CLI ONB_WPA_CTRL=$WPA_CTRL ONB_STA_IFACE=$STA_IFACE \
    ONB_WIFI_CONF_IN=$WIFI_CONF_IN ONB_WIFI_COUNTRY=$WIFI_COUNTRY \
        "$PYTHON" "$APP_DIR/portal.py" < /dev/null >> "$LOG" 2>&1 &
    echo $! > "$RUN_DIR/portal.pid"
}

ap_down() {
    [ -f "$RUN_DIR/ap_up" ] && log "closing setup network"
    kill_pidfile "$RUN_DIR/portal.pid"
    kill_pidfile "$RUN_DIR/dnsmasq.pid"
    kill_pidfile "$RUN_DIR/hostapd.pid"
    fw_close
    "$IFCONFIG" "$AP_IFACE" 0.0.0.0 2>/dev/null
    "$IFCONFIG" "$AP_IFACE" down 2>/dev/null
    rm -f "$RUN_DIR/ap_up" "$RUN_DIR/ap_channel"
}

ap_healthy() {
    pidfile_alive "$RUN_DIR/hostapd.pid" && pidfile_alive "$RUN_DIR/dnsmasq.pid" &&
        pidfile_alive "$RUN_DIR/portal.pid"
}

ap_has_clients() {
    # someone associated to the setup network, or used the portal recently
    n=$("$HOSTAPD_CLI" -p "$HOSTAPD_CTRL" -i "$AP_IFACE" all_sta 2>/dev/null |
        grep -c '^[0-9a-fA-F][0-9a-fA-F]:')
    [ "${n:-0}" -gt 0 ] && return 0
    if [ -f "$RUN_DIR/portal.activity" ]; then
        a=$(cat "$RUN_DIR/portal.activity" 2>/dev/null)
        [ -n "$a" ] && [ $(( $(now) - a )) -lt 180 ] && return 0
    fi
    return 1
}

scan_snapshot() {   # cache nearby networks for the portal (radio must be free)
    wpa scan > /dev/null
    $SLEEP 5
    wpa scan_results > "$RUN_DIR/scan.txt.tmp" && mv "$RUN_DIR/scan.txt.tmp" "$RUN_DIR/scan.txt"
}

rapid_tick() {  # clear the power-cycle counter once we've been up long enough
    [ -n "$RAPID_START" ] || return 0
    if [ $(( $(now) - RAPID_START )) -ge "$RAPID_WINDOW" ]; then
        rm -f "$STATE_DIR/bootcount"; sync
        RAPID_START=
    fi
}

# ---- the setup-mode loop ---------------------------------------------------------
# $1 = auto   : started because Wi-Fi does not work; ends when Wi-Fi works.
#      forced : started by hand; ends after a successful join, "stop", or
#               FORCE_TIMEOUT without activity.
cleanup() {
    ap_down
    if ! is_connected; then
        wpa reconnect > /dev/null
        wait_join "$JOIN_TIMEOUT" && log "back on Wi-Fi (ip $(sta_ip))"
    fi
    rm -f "$LOOP_PID" "$RUN_DIR/mode" "$RUN_DIR/stop" "$RUN_DIR/joining"
    log "setup mode ended"
}

run_setup() {
    mode=$1
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    if pidfile_alive "$LOOP_PID"; then
        log "setup mode already running"
        return 0
    fi
    echo $$ > "$LOOP_PID"
    echo "$mode" > "$RUN_DIR/mode"
    rm -f "$RUN_DIR/request.conf" "$RUN_DIR/stop" "$RUN_DIR/last_result"
    trap 'cleanup; exit 0' TERM INT HUP
    log "entering setup mode ($mode)"

    scan_snapshot
    # auto: the station isn't connected anyway; stop it scanning so the AP is
    # stable. forced: keep the existing connection, the AP shares its channel.
    [ "$mode" = auto ] && wpa disconnect > /dev/null
    ap_up
    start=$(now); last_retry=$start; failures=0

    while :; do
        $SLEEP 2
        rapid_tick
        if [ -f "$RUN_DIR/stop" ]; then log "stop requested"; break; fi

        if [ -f "$RUN_DIR/request.conf" ]; then
            mv "$RUN_DIR/request.conf" "$RUN_DIR/joining.conf"
            label=$(cat "$RUN_DIR/request.ssid" 2>/dev/null)
            echo "$label" > "$RUN_DIR/joining"
            log "portal asked to join '$label'"
            $SLEEP 3              # let the "connecting..." page reach the phone
            ap_down
            cp "$WIFI_CONF" "$RUN_DIR/previous.conf" 2>/dev/null
            if try_conf "$RUN_DIR/joining.conf" "$JOIN_TIMEOUT"; then
                save_conf "$RUN_DIR/joining.conf" "$label"
                set_result ok "$label"
                log "joined '$label' (ip $(sta_ip)); credentials saved"
                rm -f "$RUN_DIR/joining.conf"
                break
            fi
            log "joining '$label' failed: $JOIN_RESULT"
            set_result "$JOIN_RESULT" "$label"
            rm -f "$RUN_DIR/joining" "$RUN_DIR/joining.conf"
            if [ -f "$RUN_DIR/previous.conf" ]; then apply_wifi_conf "$RUN_DIR/previous.conf"; fi
            scan_snapshot
            if [ "$mode" = forced ]; then
                # back to the previous network first, so the AP can share its channel
                wpa enable_network all > /dev/null; wpa reconnect > /dev/null
                wait_join "$JOIN_TIMEOUT" || wpa disconnect > /dev/null
            else
                wpa disconnect > /dev/null
            fi
            ap_up
            last_retry=$(now)
            continue
        fi

        t=$(now)

        if [ "$mode" = auto ] && is_connected; then
            # something (e.g. the vendor network stack) reconnected the station
            log "Wi-Fi is working again (ip $(sta_ip))"
            break
        fi

        if [ "$mode" = auto ] && [ $((t - last_retry)) -ge "$RETRY_INTERVAL" ]; then
            last_retry=$t
            if [ "$(network_count)" -gt 0 ] && ! ap_has_clients; then
                log "retrying the saved network for ${RETRY_WINDOW}s"
                ap_down
                wpa enable_network all > /dev/null
                wpa reconnect > /dev/null
                if wait_join "$RETRY_WINDOW"; then
                    log "saved network is back (ip $(sta_ip))"
                    break
                fi
                scan_snapshot
                wpa disconnect > /dev/null
                ap_up
                last_retry=$(now)
            fi
        fi

        if ! ap_healthy; then
            failures=$((failures + 1))
            log "setup network not healthy (attempt $failures), restarting it"
            ap_down
            if [ "$mode" = forced ] && [ "$failures" -gt 5 ]; then
                log "setup network keeps failing, giving up"
                break
            fi
            [ "$failures" -gt 3 ] && $SLEEP 30
            ap_up
            continue
        fi
        failures=0

        if [ "$mode" = forced ] && [ $((t - start)) -ge "$FORCE_TIMEOUT" ]; then
            if ap_has_clients; then
                start=$t      # someone is busy with the page, give them time
            else
                log "nobody used the setup network for ${FORCE_TIMEOUT}s, giving up"
                break
            fi
        fi
    done
    trap - TERM INT HUP
    cleanup
    return 0
}

# ---- commands ----------------------------------------------------------------------
cmd_boot() {
    mkdir -p "$RUN_DIR" "$STATE_DIR"
    log "boot: onboarding starting"
    wait_wpa 60 || log "wpa_supplicant is not answering (continuing anyway)"
    restore_saved

    force=
    if [ -f "$STATE_DIR/force" ]; then
        rm -f "$STATE_DIR/force"; sync
        force="requested with force-next-boot"
    fi
    if [ "${RAPID_BOOTS:-0}" -gt 0 ]; then
        c=$(cat "$STATE_DIR/bootcount" 2>/dev/null)
        case "$c" in ''|*[!0-9]*) c=0 ;; esac
        c=$((c + 1))
        if [ "$c" -ge "$RAPID_BOOTS" ]; then
            rm -f "$STATE_DIR/bootcount"; sync
            force="${force:-speaker was power-cycled $c times quickly}"
        else
            echo "$c" > "$STATE_DIR/bootcount"; sync
            RAPID_START=$(now)
        fi
    fi
    if [ -n "$force" ]; then
        log "boot: setup mode forced ($force)"
        run_setup forced
    fi

    if [ "$(network_count)" -eq 0 ]; then
        log "boot: no Wi-Fi network configured"
        run_setup auto
    elif wait_connected "$BOOT_TIMEOUT"; then
        log "boot: Wi-Fi connected (ip $(sta_ip))"
    else
        log "boot: no Wi-Fi after ${BOOT_TIMEOUT}s (state $(wpa_state))"
        run_setup auto
    fi

    # Normal operation. Finish the power-cycle window, then optionally watch.
    while [ -n "$RAPID_START" ]; do $SLEEP 5; rapid_tick; done
    [ "${LOST_TIMEOUT:-0}" -gt 0 ] || exit 0
    log "watching Wi-Fi (setup mode after ${LOST_TIMEOUT}s without it)"
    lost_since=
    while :; do
        $SLEEP 15
        if is_connected || pidfile_alive "$LOOP_PID"; then lost_since=; continue; fi
        [ -n "$lost_since" ] || lost_since=$(now)
        if [ $(( $(now) - lost_since )) -ge "$LOST_TIMEOUT" ]; then
            log "Wi-Fi lost for ${LOST_TIMEOUT}s"
            run_setup auto
            lost_since=
        fi
    done
}

detach() {      # run "$SELF $*" in the background, surviving the SSH session
    if command -v setsid > /dev/null 2>&1; then
        setsid sh "$SELF" "$@" < /dev/null > /dev/null 2>&1 &
    else
        nohup sh "$SELF" "$@" < /dev/null > /dev/null 2>&1 &
    fi
}

cmd_start() {
    mkdir -p "$RUN_DIR"
    if pidfile_alive "$LOOP_PID"; then echo "Setup mode is already running."; return 0; fi
    echo "Starting setup mode: network '$(ap_ssid)' should appear within ~15 seconds."
    echo "The current Wi-Fi normally stays connected (the setup network shares its channel);"
    echo "if that is not possible the speaker leaves it while setup mode runs."
    echo "Setup mode ends after a successful setup, 'onboarding stop', or ${FORCE_TIMEOUT}s unused."
    echo "Progress: onboarding status / onboarding log"
    detach _setup forced
}

cmd_stop() {
    if ! pidfile_alive "$LOOP_PID"; then echo "Setup mode is not running."; return 0; fi
    touch "$RUN_DIR/stop"
    i=0
    while pidfile_alive "$LOOP_PID" && [ "$i" -lt 40 ]; do $SLEEP 1; i=$((i + 1)); done
    if pidfile_alive "$LOOP_PID"; then echo "Setup mode did not stop (see 'onboarding log')."; return 1; fi
    echo "Setup mode stopped."
}

cmd_status() {
    if pidfile_alive "$LOOP_PID"; then
        echo "setup mode : RUNNING ($(cat "$RUN_DIR/mode" 2>/dev/null))"
        if [ -f "$RUN_DIR/ap_up" ]; then
            echo "setup net  : $(cat "$RUN_DIR/ap_up") channel $(cut -d' ' -f1 "$RUN_DIR/ap_channel" 2>/dev/null) at http://$AP_IP/"
        else
            echo "setup net  : NOT UP (see 'onboarding log')"
        fi
        [ -f "$RUN_DIR/joining" ] && echo "joining    : $(cat "$RUN_DIR/joining")"
    else
        echo "setup mode : off"
    fi
    echo "wifi state : $(wpa_state)"
    echo "wifi ssid  : $(wpa status | sed -n 's/^ssid=//p')"
    echo "wifi ip    : $(sta_ip)"
    if valid_conf "$SAVED_CONF"; then
        echo "saved wifi : $(cat "$SAVED_LABEL" 2>/dev/null) ($SAVED_CONF)"
    else
        echo "saved wifi : none (using the firmware default $WIFI_CONF_IN)"
    fi
    [ -f "$RUN_DIR/last_result" ] && echo "last try   : $(head -n 1 "$RUN_DIR/last_result") '$(sed -n 2p "$RUN_DIR/last_result")'"
    [ -f "$STATE_DIR/force" ] && echo "next boot  : setup mode (force-next-boot)"
    return 0
}

make_conf() {   # make_conf OUTFILE SSID PASSWORD  -> wpa_supplicant.conf
    printf '%s\n%s\n' "$2" "$3" |
        ONB_WIFI_CONF_IN=$WIFI_CONF_IN ONB_WIFI_COUNTRY=$WIFI_COUNTRY \
        "$PYTHON" "$APP_DIR/portal.py" --make-conf "$1"
}

cmd_join() {
    [ -n "$1" ] || { echo "usage: onboarding join SSID [PASSWORD]"; return 2; }
    mkdir -p "$RUN_DIR"
    make_conf "$RUN_DIR/cli.conf" "$1" "$2" || return 1
    if pidfile_alive "$LOOP_PID"; then
        printf '%s\n' "$1" > "$RUN_DIR/request.ssid"
        mv "$RUN_DIR/cli.conf" "$RUN_DIR/request.conf"
        echo "Handed to the running setup mode. Check 'onboarding status' in a minute."
        return 0
    fi
    echo "Joining '$1'. If this session drops, the speaker is switching networks."
    cp "$WIFI_CONF" "$RUN_DIR/previous.conf"
    if try_conf "$RUN_DIR/cli.conf" "$JOIN_TIMEOUT"; then
        save_conf "$RUN_DIR/cli.conf" "$1"
        log "joined '$1' from command line; saved"
        echo "Connected, ip $(sta_ip). Saved."
        rm -f "$RUN_DIR/cli.conf"
        return 0
    fi
    log "command-line join of '$1' failed: $JOIN_RESULT; restoring previous"
    echo "Failed ($JOIN_RESULT). Going back to the previous network."
    apply_wifi_conf "$RUN_DIR/previous.conf"
    wpa reconnect > /dev/null
    rm -f "$RUN_DIR/cli.conf"
    return 1
}

cmd_forget() {
    rm -f "$SAVED_CONF" "$SAVED_LABEL"; sync
    echo "Saved Wi-Fi deleted. The current connection stays until the next reboot;"
    echo "after that the speaker uses the firmware default (or opens setup mode)."
}

cmd_scan() {
    wpa scan > /dev/null; $SLEEP 4
    wpa scan_results | tail -n +2 | sort -t "$(printf '\t')" -k3 -n -r |
        awk -F '\t' '{ printf "%-5s %4s dBm  %-34s %s\n", ($2 < 3000 ? "2.4G" : "5G"), $3, $5, $4 }'
}

case "$1" in
    boot)            cmd_boot ;;
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    status|"")       cmd_status ;;
    join)            shift; cmd_join "$@" ;;
    forget)          cmd_forget ;;
    force-next-boot) mkdir -p "$STATE_DIR"; touch "$STATE_DIR/force"; sync
                     echo "Setup mode will open at the next boot." ;;
    scan)            cmd_scan ;;
    log)             cat "$LOG" 2>/dev/null ;;
    _setup)          run_setup "${2:-forced}" ;;
    _check)          # read-only: what would the boot logic decide right now?
                     w=down; wait_wpa 1 && w=up
                     c=no; is_connected && c=yes
                     s=no; valid_conf "$SAVED_CONF" && s=yes
                     echo "wpa_supplicant=$w networks=$(network_count) connected=$c saved=$s ap_ssid=$(ap_ssid)" ;;
    _aptest)         # hostapd-only check, safe while on Wi-Fi: uses ONLY the station's
                     # current channel, never touches wlan0, stops after ~2 s.
                     mkdir -p "$RUN_DIR"; chmod 0711 "$RUN_DIR"
                     sf=$(sta_assoc_freq); set -- $(freq_to_chan "$sf")
                     if [ -z "$1" ]; then echo "station not associated: refusing (test runs only on its channel)"; exit 1; fi
                     prepare_ap_dir; AP_START_TIMEOUT=6; r=1
                     if start_hostapd "$(ap_ssid)-TEST" "$1" "$2"; then
                         r=0; echo "OK: AP enabled on channel $1 (station at $sf MHz)"
                         "$HOSTAPD_CLI" -p "$HOSTAPD_CTRL" -i "$AP_IFACE" status | grep -E '^(state|channel|num_sta)='
                         echo "hostapd $(grep -E '^Uid' /proc/$(cat "$RUN_DIR/hostapd.pid")/status 2>/dev/null)"
                         $SLEEP 2
                     else
                         echo "FAILED (details in $LOG)"
                     fi
                     kill_pidfile "$RUN_DIR/hostapd.pid"
                     ls -la "$AP_DIR"; exit $r ;;
    _render)         # write the configs ap_up would use right now; start nothing
                     prepare_ap_dir
                     set -- $(freq_to_chan "$(sta_assoc_freq)")
                     write_hostapd_conf "$(ap_ssid)" "${1:-$AP_CHANNEL}" "${2:-g}"; write_dnsmasq_conf
                     echo "wrote $HOSTAPD_CONF and $RUN_DIR/dnsmasq.conf" ;;
    *) sed -n '/^# Usage:/,/^#   boot/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
