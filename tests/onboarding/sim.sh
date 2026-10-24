#!/bin/sh
# Simulation tests for onboarding.sh: runs the real script against stub tools
# (test/stubs/stub) and a fake clock, so every path can be exercised on a PC.
#
#   docker run --rm -v "$PWD":/kit alpine:latest sh /kit/tests/onboarding/sim.sh             # busybox ash
#   docker run --rm -v "$PWD":/kit debian:bookworm-slim bash /kit/tests/onboarding/sim.sh   # bash (= device /bin/sh)
#
# (run from the onboarding/ directory)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SCRIPT=${ONB_SCRIPT:-$ROOT/../overlay/usr/share/onboarding/onboarding.sh}
SHELL_UNDER_TEST=${SHELL_UNDER_TEST:-sh}
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); [ -n "$SIM" ] && tail -n 15 "$SIM/run/onboarding.log" | sed 's/^/        | /'; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

setup() {   # fresh simulated speaker
    SIM=$(mktemp -d); export SIM
    mkdir -p "$SIM/bin" "$SIM/wifi" "$SIM/state" "$SIM/run" "$SIM/sys/wlan0"
    for t in wpa_cli ifconfig hostapd hostapd_cli dnsmasq python dhcpcd setprop iptables logcat simsleep; do
        ln -s "$HERE/stubs/stub" "$SIM/bin/$t"
    done
    echo d8:00:00:00:12:ab > "$SIM/sys/wlan0/address"
    echo "100.00 0.00" > "$SIM/uptime"
    hex home > "$SIM/good_ssid"
    hex rightpass > "$SIM/good_psk"
    printf 'ctrl_interface=/data/wifi\nupdate_config=1\ncountry=US\n' > "$SIM/conf.in"
    cp "$SIM/conf.in" "$SIM/wifi/wpa_supplicant.conf"     # what the boot script leaves
    echo DISCONNECTED > "$SIM/wpastate"
    echo 2462 > "$SIM/sta_freq"; echo 11 > "$SIM/sta_chan"     # home router on channel 11
    export SIM_WIFI_CONF="$SIM/wifi/wpa_supplicant.conf"
    cat > "$SIM/onb.conf" <<EOF
STATE_DIR=$SIM/state
RUN_DIR=$SIM/run
LOG_DIR=$SIM/run
WIFI_CONF=$SIM/wifi/wpa_supplicant.conf
WIFI_CONF_IN=$SIM/conf.in
SYS_NET=$SIM/sys
UPTIME_FILE=$SIM/uptime
WPA_CLI=$SIM/bin/wpa_cli
HOSTAPD=$SIM/bin/hostapd
HOSTAPD_CLI=$SIM/bin/hostapd_cli
DNSMASQ=$SIM/bin/dnsmasq
PYTHON=$SIM/bin/python
IPTABLES=$SIM/bin/iptables
IFCONFIG=$SIM/bin/ifconfig
SETPROP=$SIM/bin/setprop
DHCPCD=$SIM/bin/dhcpcd
SLEEP=$SIM/bin/simsleep
LOGCAT=$SIM/bin/logcat
EOF
    export ONB_CONF="$SIM/onb.conf" ONB_QUIET=1
}

teardown() {
    # every scenario: hostapd (which runs as "wifi" on the speaker) could always
    # read its config and use its directory
    if [ -s "$SIM/perm_errors" ]; then bad "hostapd permissions: $(sort -u "$SIM/perm_errors" | tr '\n' ';')"
    else ok "hostapd permissions ok"; fi
    # stop any leftover fake daemons (stub hostapd/dnsmasq/portal are "sleep")
    for f in "$SIM"/run/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
    kill $(jobs -p) 2>/dev/null
    rm -rf "$SIM"; SIM=
}

onb() { $SHELL_UNDER_TEST "$SCRIPT" "$@"; }

wait_for() {    # wait_for "<shell condition>" [real seconds]
    i=0; lim=$(( ${2:-20} * 10 ))
    while [ "$i" -lt "$lim" ]; do eval "$1" && return 0; sleep 0.1; i=$((i + 1)); done
    return 1
}

request() {     # what the portal writes when the user presses Connect
    printf '%s\n%s\n' "$1" "$2" | "$SIM/bin/python" --make-conf "$SIM/run/request.conf.tmp"
    echo "$1" > "$SIM/run/request.ssid"
    mv "$SIM/run/request.conf.tmp" "$SIM/run/request.conf"
}

ap_running() { [ -f "$SIM/run/ap_up" ] && [ "$(wc -l < "$SIM/fw_rules" 2>/dev/null)" -eq 5 ] && [ "$(cat "$SIM/p2p0_ip" 2>/dev/null)" = 192.168.4.1 ]; }

echo "== shell under test: $SHELL_UNDER_TEST ($(readlink -f "$(command -v $SHELL_UNDER_TEST)"))"

echo "== 1. first boot, no Wi-Fi configured: wrong password, then right one"
setup
touch "$SIM/router_on"
onb boot & BOOT=$!
check "setup network comes up" "wait_for ap_running"
check "SSID derived from MAC" "grep -q '^ssid=Invoke-Setup-12AB$' '$SIM/run/ap/hostapd.conf'"
check "open network by default" "! grep -q wpa_passphrase '$SIM/run/ap/hostapd.conf'"
check "station told to stay quiet while AP is up" "grep -q 'wpa_cli disconnect' '$SIM/calls'"
check "dnsmasq answers every name with the portal" "grep -q 'address=/#/192.168.4.1' '$SIM/run/dnsmasq.conf'"
request home wrongpass
check "wrong password reported" "wait_for 'grep -q wrong_key $SIM/run/last_result 2>/dev/null'"
check "setup network back after failure" "wait_for ap_running"
check "failed password not saved" "[ ! -f '$SIM/state/wpa_supplicant.conf' ]"
check "previous config restored after failure" "wait_for 'cmp -s $SIM/conf.in $SIM/wifi/wpa_supplicant.conf'"
request home rightpass
check "boot command finishes after success" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "credentials saved persistently" "grep -q 'ssid=$(hex home)' '$SIM/state/wpa_supplicant.conf'"
check "saved label" "[ \"\$(cat $SIM/state/saved_ssid.txt)\" = home ]"
check "setup network closed" "[ ! -f '$SIM/run/ap_up' ] && [ ! -s '$SIM/fw_rules' ] && [ ! -f '$SIM/p2p0_ip' ]"
check "fake daemons stopped" "! ls $SIM/run/*.pid >/dev/null 2>&1"
check "connected with IP" "[ \"\$(cat $SIM/ip)\" = 10.0.0.5 ]"
check "result ok for portal" "head -n 1 '$SIM/run/last_result' | grep -qx ok"
check "power-cycle counter cleared after window" "[ ! -f '$SIM/state/bootcount' ]"
teardown

echo "== 2. reboot with saved credentials (firmware reset wpa_supplicant.conf)"
setup
touch "$SIM/router_on"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
onb boot & BOOT=$!
check "boot finishes" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "saved config copied over boot default" "cmp -s '$SIM/state/wpa_supplicant.conf' '$SIM/wifi/wpa_supplicant.conf'"
check "connected" "[ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
check "no setup network" "! grep -q '^hostapd' '$SIM/calls'"
check "power-cycle counter cleared" "[ ! -f '$SIM/state/bootcount' ]"
teardown

echo "== 3. router off at boot, comes back later (background retry)"
setup
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
onb boot & BOOT=$!
check "setup network after BOOT_TIMEOUT" "wait_for ap_running"
touch "$SIM/router_on"
check "returns to normal on retry" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "retry was logged" "grep -q 'saved network is back' '$SIM/run/onboarding.log'"
check "AP closed" "[ ! -f '$SIM/run/ap_up' ]"
teardown

echo "== 4. retry is skipped while someone uses the setup page"
setup
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
touch "$SIM/ap_clients"
onb boot & BOOT=$!
check "setup network up" "wait_for ap_running"
touch "$SIM/router_on"
sleep 3
check "no retry while a phone is connected" "! grep -q 'retrying the saved network' '$SIM/run/onboarding.log'"
rm -f "$SIM/ap_clients"
check "retry once phone leaves" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
teardown

echo "== 5. DHCP needs a kick after joining"
setup
touch "$SIM/router_on" "$SIM/dhcp_needs_kick"
onb boot & BOOT=$!
check "setup network up" "wait_for ap_running"
request home rightpass
check "join succeeds" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "dhcpcd was kicked" "grep -q 'ctl.start dhcpcd_wlan0' '$SIM/calls'"
check "saved" "[ -f '$SIM/state/wpa_supplicant.conf' ]"
teardown

echo "== 6. network not in range -> not_found, still in setup mode"
setup
onb boot & BOOT=$!
check "setup network up" "wait_for ap_running"
request elsewhere somepass1
check "not_found reported" "wait_for 'grep -q not_found $SIM/run/last_result 2>/dev/null' 30"
check "AP back" "wait_for ap_running"
touch "$SIM/run/stop"
check "stop file ends setup mode" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
teardown

echo "== 7. power-cycle trick: 3 short boots force setup mode"
setup
touch "$SIM/router_on"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
for n in 1 2; do
    onb boot & BOOT=$!
    wait_for "[ \"\$(cat $SIM/state/bootcount 2>/dev/null)\" = $n ]"
    kill "$BOOT" 2>/dev/null; wait "$BOOT" 2>/dev/null     # "unplugged" inside the window
done
check "counter at 2 after two short boots" "[ \"\$(cat $SIM/state/bootcount)\" = 2 ]"
onb boot & BOOT=$!
check "third boot opens setup network although Wi-Fi works" "wait_for ap_running"
check "counter reset" "[ ! -f '$SIM/state/bootcount' ]"
check "mode is forced" "[ \"\$(cat $SIM/run/mode)\" = forced ]"
check "forced mode gives up after FORCE_TIMEOUT" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "reconnected to saved network" "[ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
teardown

echo "== 8. 'onboarding start' / 'status' / 'stop' from a shell"
setup
touch "$SIM/router_on"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/wifi/wpa_supplicant.conf"
attempt_out=$("$SIM/bin/wpa_cli" reconnect)
onb start > "$SIM/out" 2>&1
check "start announces SSID" "grep -q Invoke-Setup-12AB '$SIM/out'"
check "setup network up" "wait_for ap_running"
check "status shows running" "onb status | grep -q 'setup mode : RUNNING (forced)'"
onb stop > "$SIM/out" 2>&1
check "stop works" "grep -q 'Setup mode stopped' '$SIM/out'"
check "AP closed" "[ ! -f '$SIM/run/ap_up' ] && [ ! -s '$SIM/fw_rules' ]"
check "station reconnected" "[ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
teardown

echo "== 9. 'onboarding join' from a shell, wrong then right"
setup
touch "$SIM/router_on"
onb join home badpass99 > "$SIM/out" 2>&1
check "wrong password rejected" "grep -q 'Failed (wrong_key)' '$SIM/out'"
check "nothing saved" "[ ! -f '$SIM/state/wpa_supplicant.conf' ]"
onb join home rightpass > "$SIM/out" 2>&1
check "right password joins" "grep -q 'Connected, ip 10.0.0.5' '$SIM/out'"
check "saved" "grep -q 'ssid=$(hex home)' '$SIM/state/wpa_supplicant.conf'"
onb forget > /dev/null
check "forget deletes saved" "[ ! -f '$SIM/state/wpa_supplicant.conf' ]"
onb force-next-boot > /dev/null
check "force-next-boot flag" "[ -f '$SIM/state/force' ]"
teardown

echo "== 10. hostapd keeps failing in forced mode -> gives up cleanly"
setup
touch "$SIM/router_on" "$SIM/hostapd_fails" "$SIM/state/force"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
onb boot & BOOT=$!
check "boot finishes" "wait_for '! kill -0 $BOOT 2>/dev/null' 60"
check "gave up" "grep -q 'keeps failing, giving up' '$SIM/run/onboarding.log'"
check "back on Wi-Fi" "[ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
check "firewall rule removed" "[ ! -s '$SIM/fw_rules' ]"
teardown

echo "== 11. DHCP needs a kick: background retry and leaving setup mode"
setup
touch "$SIM/dhcp_needs_kick"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/state/wpa_supplicant.conf"
onb boot & BOOT=$!
check "setup network up" "wait_for ap_running"
touch "$SIM/router_on"
check "retry gets an IP via dhcp kick" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
check "connected with IP" "[ \"\$(cat $SIM/ip 2>/dev/null)\" = 10.0.0.5 ]"
teardown
setup
touch "$SIM/router_on" "$SIM/dhcp_needs_kick"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/wifi/wpa_supplicant.conf"
onb start > /dev/null 2>&1
check "forced setup network up" "wait_for ap_running"
onb stop > /dev/null 2>&1
check "after stop: station back with IP (dhcp kicked)" "[ \"\$(cat $SIM/ip 2>/dev/null)\" = 10.0.0.5 ]"
check "log says back on Wi-Fi" "grep -q 'back on Wi-Fi' '$SIM/run/onboarding.log'"
teardown

echo "== 12. forced setup while on Wi-Fi: AP shares the station's channel, station stays"
setup
touch "$SIM/router_on"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/wifi/wpa_supplicant.conf"
"$SIM/bin/wpa_cli" reconnect > /dev/null
onb start > /dev/null 2>&1
check "setup network up" "wait_for ap_running"
check "AP on channel 11 (station's)" "grep -q '^channel=11$' '$SIM/run/ap/hostapd.conf'"
check "only one hostapd attempt" "[ \"\$(cat $SIM/hostapd_channels | tr '\\n' ' ')\" = '11 ' ]"
check "station not disconnected" "! grep -q 'wpa_cli disconnect' '$SIM/calls' && [ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
check "status shows channel" "onb status | grep -q 'channel 11 at http'"
check "hostapd config not world-writable, dir opened for hostapd" "[ \"\$(stat -c %a $SIM/run/ap/hostapd.conf)\" = 644 ] && [ \"\$(stat -c %a $SIM/run/ap)\" = 777 ]"
check "run dir only traversable" "[ \"\$(stat -c %a $SIM/run)\" = 711 ]"
check "keys stay private" "[ \"\$(stat -c %a $SIM/run/onboarding.log)\" = 600 ]"
request home rightpass
check "join from forced mode works" "wait_for 'grep -qx ok $SIM/run/last_result 2>/dev/null' 30"
onb stop > /dev/null 2>&1
teardown

echo "== 13. station on a 5 GHz channel the AP can't use -> station dropped, AP on 6"
setup
touch "$SIM/router_on"
echo 5500 > "$SIM/sta_freq"; echo 100 > "$SIM/sta_chan"; echo 100 > "$SIM/bad_channels"
printf 'ctrl_interface=/data/wifi\nupdate_config=1\n\nnetwork={\n\tssid=%s\n\tpsk=%s\n}\n' "$(hex home)" "$(hex rightpass)" > "$SIM/wifi/wpa_supplicant.conf"
"$SIM/bin/wpa_cli" reconnect > /dev/null
onb start > /dev/null 2>&1
check "setup network up" "wait_for ap_running"
check "tried 100 (802.11a) then 6" "[ \"\$(cat $SIM/hostapd_channels | tr '\\n' ' ')\" = '100 6 ' ]"
check "first attempt used hw_mode=a" "grep -q 'channel 100 (802.11a)' '$SIM/run/onboarding.log'"
check "station disconnected to free the radio" "grep -q 'wpa_cli disconnect' '$SIM/calls'"
check "hostapd's logcat lines copied into the log" "grep -q 'logcat: E/hostapd.*Failed to set beacon parameters' '$SIM/run/onboarding.log'"
onb stop > /dev/null 2>&1
check "station back after stop" "[ \"\$(cat $SIM/wpastate)\" = COMPLETED ]"
teardown

echo "== 14. auto mode, AP_CHANNEL unusable -> next channel, failure is logged"
setup
echo 6 > "$SIM/bad_channels"
onb boot & BOOT=$!
check "setup network up" "wait_for ap_running"
check "fell back to channel 1" "grep -q '^channel=1$' '$SIM/run/ap/hostapd.conf'"
check "reason logged" "grep -q 'hostapd did not come up on channel 6 (exited)' '$SIM/run/onboarding.log'"
check "logcat lines logged" "grep -q 'logcat: E/hostapd.*Interface initialization failed' '$SIM/run/onboarding.log'"
touch "$SIM/run/stop"
check "stops" "wait_for '! kill -0 $BOOT 2>/dev/null' 30"
teardown

echo "== 15. AP can't start anywhere (auto): clear error, keeps retrying"
setup
touch "$SIM/hostapd_fails"
onb boot & BOOT=$!
check "error logged" "wait_for 'grep -q \"ERROR: could not start the setup network on any channel\" $SIM/run/onboarding.log'"
check "retries" "wait_for 'grep -q \"not healthy (attempt 2)\" $SIM/run/onboarding.log'"
check "status says NOT UP" "onb status | grep -q 'NOT UP'"
touch "$SIM/run/stop"
check "stops" "wait_for '! kill -0 $BOOT 2>/dev/null' 60"
teardown

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
