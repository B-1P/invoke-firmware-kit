#!/bin/bash
# Smoke test for portal.py running in TEST MODE (see "Testing" in INTEGRATION.md).
# Usage: test/portal-smoke.sh HOST:PORT [ssh-command-for-device]
# The portal must have been started with ONB_RUN_DIR=$RUN, ONB_NO_SCAN=1, and
# test/fake-scan.txt copied to $RUN/scan.txt. The optional ssh command is used
# to read back the request.conf files the portal writes on the device.
D=${1:?host:port}
SSH=${2:-}
RUN=${RUN:-/data/onboarding/test/run}
H="Host: 192.168.4.1"
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }
hex()  { printf '%s' "$1" | xxd -p | tr -d '\n'; }
dev()  { [ -n "$SSH" ] && $SSH "$1"; }

probe() {   # host path expected-code [expected-location]
    out=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $1" "http://$D$2")
    exp="$3 $4"
    [ "$out" = "$exp" ] && ok "GET $1$2 -> $out" || bad "GET $1$2" "got '$out' want '$exp'"
}
probe captive.apple.com /hotspot-detect.html 302 http://192.168.4.1/
probe connectivitycheck.gstatic.com /generate_204 302 http://192.168.4.1/
probe clients3.google.com /generate_204 302 http://192.168.4.1/
probe www.msftconnecttest.com /connecttest.txt 302 http://192.168.4.1/
probe www.msftncsi.com /ncsi.txt 302 http://192.168.4.1/
probe detectportal.firefox.com /success.txt 302 http://192.168.4.1/
probe example.com /some/page 302 http://192.168.4.1/
probe 192.168.4.1 / 200
probe 192.168.4.1:80 / 200
probe 192.168.4.1 /elsewhere 302 http://192.168.4.1/
probe 192.168.4.1 /favicon.ico 404
probe 192.168.4.1 /status.txt 200
probe 192.168.4.1 /scan 200

page=$(curl -s -H "$H" "http://$D/")
echo "$page" | grep -q 'value="'"$(hex HomeNet)"'" checked' && ok "strongest usable network preselected" || bad "preselect" "HomeNet not checked"
[ "$(echo "$page" | grep -o "<span class=\"ssid\">HomeNet</span>" | wc -l | tr -d ' ')" = 1 ] && ok "duplicate SSID listed once" || bad "dedupe" "HomeNet count"
echo "$page" | grep -q 'Invoke-Setup-ABCD' && bad "own AP hidden" "listed" || ok "own setup network not listed"
echo "$page" | grep -q 'Caf&eacute;\|Café &lt;b&gt;&quot;Q&quot;t&lt;/b&gt;' && ok "escaped SSID decoded and HTML-escaped" || bad "escaping" "Café SSID"
echo "$page" | grep -q '<b>"Q' && bad "XSS" "raw markup in page" || ok "no raw markup from SSIDs"
echo "$page" | grep -q 'CorpNet</span><span class="meta">needs a user name' && ok "enterprise shown as unsupported" || bad "enterprise" ""
echo "$page" | grep -q 'OldRouter</span><span class="meta">old WEP' && ok "WEP shown as unsupported" || bad "wep" ""
echo "$page" | grep -q 'Wpa3Only</span><span class="meta">WPA3-only' && ok "WPA3-only shown as unsupported" || bad "sae" ""

post() { curl -s -H "$H" --data "$1" "http://$D/connect"; }
expect_error() {
    out=$(post "$2")
    echo "$out" | grep -q "class=\"error\">.*$3" && ok "$1" || bad "$1" "no error '$3'"
}
expect_error "password required for WPA network" "net=$(hex HomeNet)&psk=" "needs a password"
expect_error "password too short" "net=$(hex HomeNet)&psk=abc" "8 to 63"
expect_error "password too long" "net=$(hex HomeNet)&psk=$(printf '%070d' 1)" "8 to 63"
expect_error "no network chosen" "net=other&other=&psk=" "choose a network"
expect_error "SSID too long" "net=other&other=$(printf '%040d' 0)&psk=" "32 bytes"
expect_error "garbage network value" "net=zz&psk=12345678" "choose a network again"

check_req() {   # name, form, grep-pattern for request.conf
    out=$(post "$2")
    if ! echo "$out" | grep -q '<h2>Connecting'; then bad "$1" "no connecting page"; return; fi
    if [ -z "$SSH" ]; then ok "$1 (page only)"; return; fi
    conf=$(dev "cat $RUN/request.conf")
    if echo "$conf" | grep -q "$3"; then ok "$1"; else bad "$1" "request.conf: $(echo "$conf" | tr '\n' ' ')"; fi
}
check_req "WPA2 network -> hex ssid + derived psk" "net=$(hex HomeNet)&psk=password123" \
    "ssid=$(hex HomeNet)"
check_req "open network ignores typed password" "net=$(hex 'Open Cafe')&psk=whatever123" "key_mgmt=NONE"
check_req "hidden network with UTF-8 name" "net=other&other=Caf%C3%A9+Hidden&psk=secretpass" \
    "ssid=$(hex 'Café Hidden')"
check_req "64-hex raw PSK accepted" "net=$(hex HomeNet)&psk=$(printf 'ab%.0s' $(seq 32))" \
    "psk=$(printf 'ab%.0s' $(seq 32))"
check_req "password with quotes/ampersand/UTF-8" "net=$(hex HomeNet)&psk=p%40ss+w%22rd%C3%A9%26%3D" \
    "key_mgmt=WPA-PSK"

# HTTP edge cases: no Host header, junk request line
r=$(printf 'GET / HTTP/1.0\r\n\r\n' | nc -w 3 "${D%:*}" "${D#*:}" | head -1 | tr -d '\r')
[ "$r" = "HTTP/1.1 302 Found" ] && ok "request without Host header redirected" || bad "no host" "$r"
printf 'xx\r\n\r\n' | nc -w 3 "${D%:*}" "${D#*:}" > /dev/null
probe 192.168.4.1 / 200   # still alive after junk

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
