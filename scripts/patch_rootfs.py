#!/usr/bin/env python3
"""Apply the kit's changes to an extracted root filesystem.

Usage: patch_rootfs.py <rootfs> <airplay-build> <overlay> <settings.json>

settings.json: root_hash, airplay_name, ssh (bool), control_bus (bool),
and optionally wifi_ssid_hex + wifi_psk_hex.

Each text edit must match the stock firmware exactly once, otherwise the
build stops.
"""
import json
import os
import shutil
import subprocess
import sys


def read(path):
    with open(path) as f:
        return f.read()


def write_keep_mode(path, text):
    mode = os.stat(path).st_mode & 0o7777
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def replace_once(path, old, new):
    text = read(path)
    count = text.count(old)
    if count != 1:
        sys.exit("expected 1 match in %s, found %d:\n%s" % (path, count, old))
    write_keep_mode(path, text.replace(old, new))


def put(src, dst, mode):
    parent = os.path.dirname(dst)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    shutil.copyfile(src, dst)
    os.chmod(dst, mode)
    os.chown(dst, 0, 0)


def comment_out_process(path, name):
    """Comment out the process={...} entry with the given name in podium.conf."""
    text = read(path)
    start = text.find("process={\n        name=%s\n" % name)
    if start < 0 or text.count("name=%s\n" % name) != 1:
        sys.exit("process entry %s not found in %s" % (name, path))
    end = text.index("}", start) + 1
    block = "\n".join("#" + line for line in text[start:end].split("\n"))
    write_keep_mode(path, text[:start] + block + text[end:])


def main():
    rootfs, airplay, overlay, settings_path = sys.argv[1:5]
    s = json.loads(read(settings_path))
    f = lambda rel: os.path.join(rootfs, rel)

    # Process manager: don't start the wifi-blocker service.
    comment_out_process(f("etc/podium/podium.conf"), "wifi-blocker")

    # Boot: start AirPlay and the /data boot hooks after the main app.
    replace_once(f("init.rc"), "    start podium\n",
                 "    start podium\n    start shairport-sync\n    start data_hooks\n"
                 "    start onboarding\n")
    if not s["ssh"]:
        replace_once(f("init.rc"), "    start sshd\n", "    #start sshd\n")

    # SSH host keys: every stock speaker shares Harman's /etc/rsa_host_key,
    # so give this build its own keys instead.
    keydir = f("etc/dropbear")
    keys = []
    for kind, bits in (("ecdsa", "256"), ("rsa", "2048")):
        key = os.path.join(keydir, "dropbear_%s_host_key" % kind)
        if os.path.exists(key):
            os.remove(key)
        subprocess.check_call(["dropbearkey", "-t", kind, "-s", bits, "-f", key],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
        os.chown(key, 0, 0)
        keys.append("-r /etc/dropbear/dropbear_%s_host_key" % kind)
    replace_once(f("init.rc"), "/usr/sbin/dropbear -r /etc/rsa_host_key ",
                 "/usr/sbin/dropbear %s " % " ".join(keys))
    for rel in ("etc/rsa_host_key", "system/etc/rsa_host_key"):
        if os.path.lexists(f(rel)):
            os.remove(f(rel))
    with open(f("init.rc"), "a") as out:
        out.write("\nservice shairport-sync /bin/logwrapper /bin/sh /usr/bin/airplay-run.sh\n"
                  "\nservice data_hooks /bin/sh /usr/bin/data-hooks.sh\n"
                  "    oneshot\n    disabled\n"
                  "\nservice onboarding /bin/sh /usr/share/onboarding/onboarding.sh boot\n"
                  "    user root\n    oneshot\n    disabled\n")

    # Firewall: allow AirPlay, plus SSH and the message bus if requested.
    rules = ["# AirPlay: RTSP control + RTP audio/control/timing",
             "iptables -A INPUT -p tcp --dport 5000 -j ACCEPT",
             "iptables -A INPUT -p udp --dport 6001:6010 -j ACCEPT"]
    if s["ssh"]:
        rules.append("iptables -A INPUT -p tcp --dport 22 -j ACCEPT")
    if s["control_bus"]:
        rules += ["iptables -A INPUT -p tcp --dport 9998 -j ACCEPT",
                  "iptables -A INPUT -p tcp --dport 9999 -j ACCEPT"]
    fw = f("usr/sbin/firewall.sh")
    replace_once(fw, "# Allow Spotify Connect\n#TODO\n", "\n".join(rules) + "\n")
    # Harman's debug flag (from the device certificate) would open SSH and
    # the bus regardless; the kit's options decide that instead.
    replace_once(fw, "# This line will be added in debug builds\n#DEBUG=1\n",
                 "# The kit decides what to open, not the debug flag.\nDEBUG=\n")
    # Accept replies to the speaker's own connections (DHCP, DNS, time,
    # AirPlay), then drop everything not allowed above. Without this,
    # ADB (5555, root without a password) and Libre's services are open
    # to the network.
    replace_once(fw, "iptables -I INPUT -i lo -j ACCEPT\n",
                 "iptables -I INPUT -i lo -j ACCEPT\n"
                 "iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT\n"
                 "iptables -A INPUT -p udp --sport 67 --dport 68 -j ACCEPT\n")
    replace_once(fw, "#iptables -A INPUT -j DROP\n", "iptables -A INPUT -j DROP\n")
    # Cortana's setup app used these; nothing needs them now, and 443 is
    # where Libre's unauthenticated setup web server would listen.
    replace_once(fw, "iptables -A INPUT -p udp --dport 48301 -j ACCEPT\n"
                     "iptables -A INPUT -p tcp --dport https -j ACCEPT\n"
                     "iptables -A INPUT -p tcp --dport 12345 -j ACCEPT\n", "")

    # Root password.
    shadow = f("etc/shadow")
    lines = read(shadow).split("\n")
    roots = [i for i, line in enumerate(lines) if line.startswith("root:")]
    if len(roots) != 1:
        sys.exit("expected one root entry in /etc/shadow")
    fields = lines[roots[0]].split(":")
    fields[1] = s["root_hash"]
    lines[roots[0]] = ":".join(fields)
    write_keep_mode(shadow, "\n".join(lines))

    # AirPlay receiver, its libraries, launcher and config.
    put(os.path.join(airplay, "shairport-sync"), f("usr/bin/shairport-sync"), 0o755)
    libdir = os.path.join(airplay, "lib")
    for lib in sorted(os.listdir(libdir)):
        put(os.path.join(libdir, lib), f("usr/lib/airplay/" + lib), 0o644)
    os.chmod(f("usr/lib/airplay"), 0o755)
    for script in ("airplay-run.sh", "airplay-source.sh", "data-hooks.sh"):
        put(os.path.join(overlay, "usr/bin", script), f("usr/bin/" + script), 0o755)
    name = s["airplay_name"].replace("\\", "").replace('"', "")
    conf = f("etc/shairport-sync.conf")
    with open(conf, "w") as out:
        out.write('general = {\n\tname = "%s";\n\tport = 5000;\n'
                  '\tudp_port_base = 6001;\n\tudp_port_range = 10;\n'
                  '\tdrift_tolerance_in_seconds = 0.002;\n};\n\n'
                  'sessioncontrol = {\n\tallow_session_interruption = "yes";\n'
                  '\trun_this_before_play_begins = "/usr/bin/airplay-source.sh playing";\n'
                  '\trun_this_after_play_ends = "/usr/bin/airplay-source.sh stopped";\n'
                  '\twait_for_completion = "no";\n};\n' % name)
    os.chmod(conf, 0o644)

    # Wi-Fi onboarding: opens a setup network with a web page when Wi-Fi
    # doesn't come up. Networks saved there live on /data and replace the
    # firmware's default config on every boot.
    onb = os.path.join(overlay, "usr/share/onboarding")
    for rel, mode in (("onboarding.sh", 0o755), ("portal.py", 0o644),
                      ("onboarding.conf", 0o644), ("www/layout.html", 0o644)):
        put(os.path.join(onb, rel), f("usr/share/onboarding/" + rel), mode)
    for d in ("usr/share/onboarding", "usr/share/onboarding/www"):
        os.chmod(f(d), 0o755)
    link = f("usr/bin/onboarding")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink("../share/onboarding/onboarding.sh", link)
    replace_once(f("sbin/wpa_supplicant_setup.sh"),
                 "\nchmod 0600 ${CONFIG_FILE}\n",
                 "\n# Wi-Fi onboarding: a network saved through the setup page wins.\n"
                 "ONB_SAVED=/data/onboarding/wpa_supplicant.conf\n"
                 "if [ -s ${ONB_SAVED} ] && grep -q '^ctrl_interface=' ${ONB_SAVED}"
                 " && grep -q '^network={' ${ONB_SAVED}; then\n"
                 "  /bin/cat ${ONB_SAVED} > ${CONFIG_FILE}\n"
                 "fi\n"
                 "\nchmod 0600 ${CONFIG_FILE}\n")

    # Optional Wi-Fi network. The speaker copies this template into place
    # on every boot.
    if s.get("wifi_ssid_hex"):
        network = ("\nnetwork={\n\tssid=%s\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n"
                   "\tscan_ssid=1\n}\n" % (s["wifi_ssid_hex"], s["wifi_psk_hex"]))
        for rel in ("system/etc/wpa_supplicant.conf.in", "etc/wpa_supplicant.conf.in"):
            path = f(rel)
            write_keep_mode(path, read(path).rstrip("\n") + "\n" + network)

    print("rootfs patched")


if __name__ == "__main__":
    main()
