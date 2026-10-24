#!/usr/bin/env python3
"""Print events published on the Invoke's WAMP message bus.

Usage: wamp_listen.py <host> [seconds] [topic ...]
Default topics: button/touch input events and volume changes.
"""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wamp_call import WebSocket  # noqa: E402

HELLO, WELCOME, GOODBYE, SUBSCRIBE, SUBSCRIBED, EVENT = 1, 2, 6, 32, 33, 36
DEFAULT_TOPICS = ["com.harman.test.inputEvent", "com.harman.volumeChanged"]


def main():
    host = sys.argv[1]
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 60
    topics = sys.argv[3:] or DEFAULT_TOPICS

    ws = WebSocket(host, 9998, "wamp.2.json")
    ws.send_text(json.dumps([HELLO, "default", {"roles": {"subscriber": {}}}]))
    if json.loads(ws.recv_text())[0] != WELCOME:
        raise SystemExit("not welcomed")

    names = {}
    for i, topic in enumerate(topics, 1):
        ws.send_text(json.dumps([SUBSCRIBE, i, {}, topic]))
        reply = json.loads(ws.recv_text())
        if reply[0] != SUBSCRIBED:
            raise SystemExit("subscribe to %s failed: %s" % (topic, reply))
        names[reply[2]] = topic
    print("listening for %ds on: %s" % (seconds, ", ".join(topics)), flush=True)

    ws.sock.settimeout(1)
    end = time.time() + seconds
    while time.time() < end:
        try:
            msg = json.loads(ws.recv_text())
        except socket.timeout:
            continue
        if msg[0] == EVENT:
            args = msg[4] if len(msg) > 4 else []
            kwargs = msg[5] if len(msg) > 5 else {}
            print("%s  %s  %s%s" % (time.strftime("%H:%M:%S"), names.get(msg[1], msg[1]),
                                    json.dumps(args), " " + json.dumps(kwargs) if kwargs else ""),
                  flush=True)
    ws.send_text(json.dumps([GOODBYE, {}, "wamp.close.normal"]))
    ws.close()


if __name__ == "__main__":
    main()
