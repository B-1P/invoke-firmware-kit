#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Captive portal for the Invoke Wi-Fi onboarding.

A deliberately tiny, single-threaded HTTP server for Python 2.7 that only
uses modules present in the speaker's stripped-down Python (socket, os, re,
time, urllib, hashlib). It never touches the Wi-Fi itself: when the user
submits the form it writes a ready-made wpa_supplicant.conf to
$ONB_RUN_DIR/request.conf and onboarding.sh (the setup loop) does the rest.

Also used by onboarding.sh as a helper:
    printf 'SSID\\nPASSWORD\\n' | python portal.py --make-conf OUTFILE
"""

import os
import re
import socket
import sys
import time
from urllib import unquote_plus

try:
    import hashlib
except ImportError:  # pragma: no cover - fallback handled in make_conf
    hashlib = None

ENV = os.environ.get
RUN_DIR = ENV('ONB_RUN_DIR', '/tmp/onboarding')
APP_DIR = ENV('ONB_APP_DIR', os.path.dirname(os.path.abspath(__file__)))
AP_IP = ENV('ONB_AP_IP', '192.168.4.1')
ADDR = ENV('ONB_ADDR', AP_IP)
PORT = int(ENV('ONB_PORT', '80'))
AP_SSID = ENV('ONB_AP_SSID', 'Invoke-Setup')
WPA_CLI = ENV('ONB_WPA_CLI', 'wpa_cli')
WPA_CTRL = ENV('ONB_WPA_CTRL', '/data/wifi')
STA_IFACE = ENV('ONB_STA_IFACE', 'wlan0')
WIFI_CONF_IN = ENV('ONB_WIFI_CONF_IN', '/system/etc/wpa_supplicant.conf.in')
WIFI_COUNTRY = ENV('ONB_WIFI_COUNTRY', '')
NO_SCAN = ENV('ONB_NO_SCAN', '') == '1'      # test mode: never trigger a scan

PORTAL = 'http://%s/' % AP_IP
PORTAL_HOSTS = (AP_IP, 'invoke.setup', 'setup.invoke')

MESSAGES = {
    'wrong_key': u'The password for “%s” was not accepted. '
                 u'Please check it (it is case-sensitive) and try again.',
    'assoc_failed': u'The speaker found “%s” but could not connect. '
                    u'If the router only allows WPA3, switch it to '
                    u'“WPA2/WPA3” mode. Otherwise check the password.',
    'not_found': u'The speaker could not find “%s”. Is the router on and '
                 u'close enough? The speaker supports 2.4 GHz and 5 GHz networks.',
    'no_ip': u'The speaker joined “%s” but the router did not give it '
             u'an address (DHCP). Try again, or restart the router.',
}


def log(msg):
    sys.stdout.write('%s portal: %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), msg))
    sys.stdout.flush()


def uptime():
    try:
        with open('/proc/uptime') as f:
            return int(float(f.read().split()[0]))
    except (IOError, ValueError):
        return int(time.time())


def read_file(path, default=''):
    try:
        with open(path) as f:
            return f.read()
    except IOError:
        return default


def write_atomic(path, data, mode=0o600):
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, path)


def esc(s):
    """HTML-escape a unicode string."""
    return (s.replace(u'&', u'&amp;').replace(u'<', u'&lt;').replace(u'>', u'&gt;')
             .replace(u'"', u'&quot;').replace(u"'", u'&#39;'))


def to_text(b):
    return b.decode('utf-8', 'replace')


# ---------------------------------------------------------------- scanning --
def wpa_unescape(s):
    """Undo wpa_supplicant's printf_encode() used for SSIDs in scan_results."""
    out = []
    i = 0
    n = len(s)
    simple = {'\\': '\\', '"': '"', 'n': '\n', 'r': '\r', 't': '\t', 'e': '\x1b'}
    while i < n:
        c = s[i]
        if c == '\\' and i + 1 < n:
            d = s[i + 1]
            if d in simple:
                out.append(simple[d])
                i += 2
                continue
            if d == 'x' and i + 3 < n and re.match(r'[0-9a-fA-F]{2}', s[i + 2:i + 4]):
                out.append(chr(int(s[i + 2:i + 4], 16)))
                i += 4
                continue
        out.append(c)
        i += 1
    return ''.join(out)


def security_of(flags):
    if 'EAP' in flags:
        return 'enterprise'
    if 'PSK' in flags:
        return 'psk'
    if 'SAE' in flags:
        return 'sae'
    if 'WEP' in flags:
        return 'wep'
    return 'open'


def parse_scan(text):
    """Return {ssid_bytes: dict(signal, freq, sec)} from wpa_cli scan_results."""
    nets = {}
    for line in text.splitlines():
        parts = line.split('\t')
        if len(parts) < 4 or not re.match(r'^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$', parts[0]):
            continue
        ssid = wpa_unescape(parts[4]) if len(parts) > 4 else ''
        if not ssid or ssid.strip('\x00') == '' or ssid.startswith(AP_SSID.rsplit('-', 1)[0] + '-'):
            continue
        try:
            freq = int(parts[1])
            sig = int(parts[2])
        except ValueError:
            continue
        sec = security_of(parts[3])
        old = nets.get(ssid)
        if old is None or sig > old['signal']:
            nets[ssid] = {'signal': sig, 'freq': freq, 'sec': sec}
    return nets


def wpa_cli(*args):
    cmd = "%s -p '%s' -i '%s' %s 2>/dev/null" % (WPA_CLI, WPA_CTRL, STA_IFACE, ' '.join(args))
    p = os.popen(cmd)
    try:
        return p.read()
    finally:
        p.close()


def networks():
    """Scan snapshot taken before the AP came up, merged with live results."""
    nets = parse_scan(read_file(os.path.join(RUN_DIR, 'scan.txt')))
    for ssid, info in parse_scan(wpa_cli('scan_results')).items():
        old = nets.get(ssid)
        if old is None or info['signal'] > old['signal']:
            nets[ssid] = info
    return sorted(nets.items(), key=lambda kv: -kv[1]['signal'])


# ------------------------------------------------------- config generation --
def conf_header():
    lines = []
    for line in read_file(WIFI_CONF_IN).splitlines():
        if line.strip().startswith('network='):
            break
        if line.strip():
            lines.append(line.rstrip())
    if not any(l.startswith('ctrl_interface=') for l in lines):
        lines.insert(0, 'ctrl_interface=/data/wifi')
    if not any(l.startswith('update_config=') for l in lines):
        lines.append('update_config=1')
    if WIFI_COUNTRY:
        lines = [l for l in lines if not l.startswith('country=')]
        lines.append('country=%s' % WIFI_COUNTRY.upper()[:2])
    return '\n'.join(lines) + '\n'


def check_inputs(ssid, password):
    """Return an error message (unicode) or None. Both args are byte strings."""
    if not ssid:
        return u'Please choose a network or type its name.'
    if len(ssid) > 32:
        return u'A Wi-Fi network name can be at most 32 bytes long.'
    if password:
        if len(password) == 64 and re.match(r'^[0-9a-fA-F]{64}$', password):
            return None
        if len(password) < 8 or len(password) > 63:
            return u'A Wi-Fi password has 8 to 63 characters.'
        if re.search(r'[\x00-\x1f\x7f]', password):
            return u'The password contains characters that are not allowed.'
    return None


def make_conf(ssid, password):
    """Build a complete wpa_supplicant.conf (bytes) for one network.

    The SSID is written as hex and the password as the derived 256-bit PSK,
    so no quoting or escaping problems are possible.
    """
    block = ['network={', '\tssid=%s' % ssid.encode('hex'), '\tscan_ssid=1']
    if not password:
        block.append('\tkey_mgmt=NONE')
    else:
        if len(password) == 64 and re.match(r'^[0-9a-fA-F]{64}$', password):
            psk = password.lower()
        elif hashlib is not None and hasattr(hashlib, 'pbkdf2_hmac'):
            psk = hashlib.pbkdf2_hmac('sha1', password, ssid, 4096, 32).encode('hex')
        else:
            psk = '"%s"' % password
        block.append('\tpsk=%s' % psk)
        block.append('\tkey_mgmt=WPA-PSK')
    block.append('}')
    return conf_header() + '\n' + '\n'.join(block) + '\n'


# ----------------------------------------------------------------- HTML --
def page(title, body, refresh=None):
    tpl = read_file(os.path.join(APP_DIR, 'www', 'layout.html'))
    if not tpl:
        tpl = (u'<!doctype html><html><head><meta charset="utf-8"><title>{{TITLE}}</title>'
               u'{{HEAD}}</head><body>{{BODY}}</body></html>')
    else:
        tpl = tpl.decode('utf-8')
    head = u''
    if refresh:
        head = u'<meta http-equiv="refresh" content="%d;url=%s">' % (refresh[0], refresh[1])
    out = (tpl.replace(u'{{TITLE}}', esc(title)).replace(u'{{HEAD}}', head)
              .replace(u'{{BODY}}', body)
              .replace(u'{{AP_SSID}}', esc(AP_SSID.decode('utf-8', 'replace'))))
    return out.encode('utf-8')


def bars(signal):
    if signal >= -55:
        return u'▂▄▆█'
    if signal >= -67:
        return u'▂▄▆'
    if signal >= -78:
        return u'▂▄'
    return u'▂'


def main_page(error=None, keep_other=u''):
    parts = []
    joining = read_file(os.path.join(RUN_DIR, 'joining')).strip()
    if joining:
        parts.append(u'<p class="note">The speaker is busy connecting to “%s”…</p>'
                     % esc(to_text(joining)))
    result = read_file(os.path.join(RUN_DIR, 'last_result')).split('\n')
    if not error and len(result) > 1 and result[0] in MESSAGES:
        error = MESSAGES[result[0]] % esc(to_text(result[1]))
    elif error:
        error = esc(error)
    if error:
        parts.append(u'<p class="error">%s</p>' % error)

    parts.append(u'<form method="post" action="%sconnect">' % PORTAL)
    parts.append(u'<h2>1. Choose your Wi-Fi</h2><div class="list">')
    nets = networks()
    first = True
    for ssid, info in nets:
        sec = info['sec']
        name = esc(to_text(ssid))
        band = u'5 GHz' if info['freq'] > 3000 else u'2.4 GHz'
        lock = u'\U0001F512 ' if sec != 'open' else u''
        if sec in ('enterprise', 'wep', 'sae'):
            why = {'enterprise': u'needs a user name, not supported',
                   'wep': u'old WEP security, not supported',
                   'sae': u'WPA3-only, not supported'}[sec]
            parts.append(u'<label class="net off"><input type="radio" disabled> '
                         u'<span class="ssid">%s</span><span class="meta">%s</span></label>'
                         % (name, why))
            continue
        parts.append(u'<label class="net"><input type="radio" name="net" value="%s"%s> '
                     u'<span class="ssid">%s</span><span class="meta">%s%s &middot; %s</span></label>'
                     % (ssid.encode('hex'), u' checked' if first else u'', name, lock,
                        bars(info['signal']), band))
        first = False
    if not nets:
        parts.append(u'<p class="note">No networks found yet. Tap “Scan again”, '
                     u'or type the name below.</p>')
    parts.append(u'<label class="net"><input type="radio" name="net" value="other"%s> '
                 u'<span class="ssid">Other / hidden network:</span></label>'
                 u'<input type="text" name="other" id="other" maxlength="32" '
                 u'autocapitalize="none" autocorrect="off" spellcheck="false" '
                 u'placeholder="Network name" value="%s" '
                 u'onfocus="document.querySelector(\'input[value=other]\').checked=true">'
                 % (u' checked' if first else u'', esc(keep_other)))
    parts.append(u'</div><p class="small"><a href="%sscan">Scan again</a></p>' % PORTAL)
    parts.append(u'<h2>2. Password</h2>'
                 u'<input type="password" name="psk" id="psk" maxlength="64" '
                 u'autocapitalize="none" autocorrect="off" spellcheck="false" '
                 u'placeholder="Wi-Fi password">'
                 u'<label class="small"><input type="checkbox" '
                 u'onclick="var p=document.getElementById(\'psk\');p.type=this.checked?\'text\':\'password\'">'
                 u' Show password</label>'
                 u'<p class="small">Leave empty for a network without a password.</p>'
                 u'<button type="submit">Connect</button></form>')
    return page(u'Invoke Wi-Fi setup', u'\n'.join(parts))


def joining_page(label):
    body = (u'<h2>Connecting…</h2>'
            u'<p>The speaker is now closing the <b>{{AP_SSID}}</b> network and joining '
            u'<b>%s</b>. This takes up to a minute.</p>'
            u'<ul><li><b>If it works:</b> {{AP_SSID}} disappears and your phone goes '
            u'back to your normal Wi-Fi. The speaker is now on your network '
            u'(for example it shows up as an AirPlay speaker).</li>'
            u'<li><b>If it does not work:</b> {{AP_SSID}} comes back after about '
            u'two minutes. Connect to it again and this page tells you what went wrong.</li></ul>'
            % esc(label))
    return page(u'Connecting…', body)


# ------------------------------------------------------------------ HTTP --
def response(status, body=b'', ctype='text/html; charset=utf-8', extra=()):
    head = ['HTTP/1.1 %s' % status,
            'Content-Type: %s' % ctype,
            'Content-Length: %d' % len(body),
            'Cache-Control: no-cache, no-store, must-revalidate',
            'Pragma: no-cache', 'Expires: 0', 'Connection: close']
    head.extend(extra)
    return '\r\n'.join(head) + '\r\n\r\n' + body


def redirect(url=None):
    url = url or PORTAL
    body = '<html><body><a href="%s">Continue to Wi-Fi setup</a></body></html>' % url
    return response('302 Found', body, extra=('Location: %s' % url,))


def parse_form(body):
    form = {}
    for pair in body.split('&'):
        if '=' in pair:
            k, v = pair.split('=', 1)
            form[unquote_plus(k)] = unquote_plus(v)
    return form


def handle_connect(form):
    net = form.get('net', '')
    other = form.get('other', '')
    password = form.get('psk', '')
    known = dict(networks())
    if net == 'other' or not net:
        ssid = other.strip()
        sec = known.get(ssid, {}).get('sec')
    else:
        try:
            ssid = net.decode('hex')
        except (TypeError, ValueError):
            return main_page(u'Please choose a network again.')
        sec = known.get(ssid, {}).get('sec')
    err = check_inputs(ssid, password)
    if not err and sec == 'psk' and not password:
        err = u'“%s” needs a password.' % to_text(ssid)
    if not err and sec == 'open':
        password = ''           # the network is open, ignore a typed password
    if err:
        return main_page(err, to_text(other))
    write_atomic(os.path.join(RUN_DIR, 'request.ssid'), ssid + '\n')
    write_atomic(os.path.join(RUN_DIR, 'request.conf'), make_conf(ssid, password))
    log('join requested for %r (%s)' % (ssid, 'open' if not password else 'password'))
    return joining_page(to_text(ssid))


def route(method, path, host, body):
    path = path.split('?', 1)[0]
    if host not in PORTAL_HOSTS:
        # Someone asked for another site, or an OS connectivity probe
        # (Apple hotspot-detect, Android generate_204, Windows connecttest /
        # ncsi, Firefox, ...). Not giving the expected answer makes the phone
        # show its "sign in to network" page, which we redirect here.
        return redirect()
    if method == 'POST' and path == '/connect':
        return response('200 OK', handle_connect(parse_form(body)))
    if path in ('/', '/index.html'):
        return response('200 OK', main_page())
    if path == '/scan':
        if not NO_SCAN:
            wpa_cli('scan')
        return response('200 OK', page(u'Scanning…',
                                       u'<p class="note">Looking for networks…</p>',
                                       refresh=(6, PORTAL)))
    if path == '/status.txt':
        txt = 'joining=%s\nlast_result=%s\n' % (
            read_file(os.path.join(RUN_DIR, 'joining')).strip(),
            read_file(os.path.join(RUN_DIR, 'last_result')).split('\n')[0])
        return response('200 OK', txt, 'text/plain; charset=utf-8')
    if path == '/favicon.ico':
        return response('404 Not Found', '')
    return redirect()


def read_request(conn):
    data = ''
    while '\r\n\r\n' not in data:
        chunk = conn.recv(2048)
        if not chunk:
            return None
        data += chunk
        if len(data) > 16384:
            return None
    head, body = data.split('\r\n\r\n', 1)
    lines = head.split('\r\n')
    try:
        method, path, _ = lines[0].split(' ', 2)
    except ValueError:
        return None
    headers = {}
    for line in lines[1:]:
        if ':' in line:
            k, v = line.split(':', 1)
            headers[k.strip().lower()] = v.strip()
    try:
        length = min(int(headers.get('content-length', '0')), 8192)
    except ValueError:
        length = 0
    while len(body) < length:
        chunk = conn.recv(2048)
        if not chunk:
            break
        body += chunk
    host = headers.get('host', '').split(':')[0].lower()
    return method.upper(), path, host, body[:length]


def touch_activity():
    try:
        write_atomic(os.path.join(RUN_DIR, 'portal.activity'), '%d\n' % uptime(), 0o644)
    except (IOError, OSError):
        pass


def serve():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    for attempt in range(30):
        try:
            srv.bind((ADDR, PORT))
            break
        except socket.error as e:
            log('bind %s:%d failed (%s), retrying' % (ADDR, PORT, e))
            time.sleep(1)
    else:
        sys.exit(1)
    srv.listen(16)
    log('listening on %s:%d (portal %s)' % (ADDR, PORT, PORTAL))
    while True:
        try:
            conn, peer = srv.accept()
        except socket.error:
            time.sleep(0.2)
            continue
        try:
            conn.settimeout(4)
            req = read_request(conn)
            if req:
                method, path, host, body = req
                touch_activity()
                conn.sendall(route(method, path, host, body))
        except Exception as e:  # never let one bad client kill the portal
            log('request from %s failed: %r' % (peer[0], e))
        finally:
            try:
                conn.close()
            except socket.error:
                pass


def cli_make_conf(out):
    lines = sys.stdin.read().split('\n')
    ssid = lines[0] if lines else ''
    password = lines[1] if len(lines) > 1 else ''
    err = check_inputs(ssid, password)
    if err:
        sys.stderr.write(err.encode('utf-8') + '\n')
        sys.exit(2)
    write_atomic(out, make_conf(ssid, password))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--make-conf':
        cli_make_conf(sys.argv[2])
    else:
        serve()
