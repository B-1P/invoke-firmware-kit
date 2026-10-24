#!/usr/bin/env python3
"""Call a procedure on the Invoke's WAMP message bus (bonefish router).

Uses WAMP over WebSocket (port 9998), JSON serialization ("wamp.2.json"),
realm "default". Standard library only. (The raw TCP port 9999 only
accepts MessagePack.)

Usage: wamp_call.py <host> <procedure> [json-args]
  e.g. wamp_call.py <speaker-ip> com.harman.ledAnimate '["L_312_d_shorttap"]'
"""
import base64
import json
import os
import socket
import struct
import sys

HELLO, WELCOME, GOODBYE, ERROR, CALL, RESULT = 1, 2, 6, 8, 48, 50


class WebSocket:
    def __init__(self, host, port, subprotocol):
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: %s\r\n\r\n"
            % (host, port, key, subprotocol)).encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SystemExit("connection closed during WebSocket handshake")
            response += chunk
        status = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status:
            raise SystemExit("WebSocket upgrade refused: %s" % status.decode(errors="replace"))
        self.buffer = response.split(b"\r\n\r\n", 1)[1]

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SystemExit("connection closed by router")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def send_text(self, text):
        self._send_frame(0x1, text.encode())

    def recv_text(self):
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode in (0x1, 0x2):
                return payload.decode()
            if opcode == 0x9:  # ping
                self._send_frame(0xA, payload)
            elif opcode == 0x8:
                raise SystemExit("router closed the connection")

    def close(self):
        self._send_frame(0x8, b"")
        self.sock.close()


def main():
    host, procedure = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else []
    ws = WebSocket(host, 9998, "wamp.2.json")

    ws.send_text(json.dumps([HELLO, "default", {"roles": {"caller": {}}}]))
    welcome = json.loads(ws.recv_text())
    if welcome[0] != WELCOME:
        raise SystemExit("not welcomed: %s" % welcome)

    ws.send_text(json.dumps([CALL, 1, {}, procedure, args]))
    reply = json.loads(ws.recv_text())
    if reply[0] == RESULT:
        print("RESULT", reply[3:] if len(reply) > 3 else "(no data)")
    elif reply[0] == ERROR:
        print("ERROR", reply[4:])
    else:
        print("unexpected", reply)

    ws.send_text(json.dumps([GOODBYE, {}, "wamp.close.normal"]))
    ws.close()


if __name__ == "__main__":
    main()
