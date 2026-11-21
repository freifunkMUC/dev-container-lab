#!/usr/bin/env python3
"""Connect the network socket of the emulator to a container interface.

Usage: relay.py PORT IFNAME GATE
The emulator connects to 127.0.0.1:PORT (-net-socket or -wifi-socket). Each
frame on the TCP stream has a 4-byte length (big endian). The frames go to
and come from IFNAME (AF_PACKET). While the file GATE exists, no frames
pass: the guest gets its firewall before it gets a link."""
import os
import select
import socket
import struct
import sys

PACKET_OUTGOING = 4
port, ifname, gate = int(sys.argv[1]), sys.argv[2], sys.argv[3]

raw = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
raw.bind((ifname, 0))
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
print(f"relay: 127.0.0.1:{port} <-> {ifname}", flush=True)

while True:
    conn, _ = srv.accept()
    print("relay: emulator connected", flush=True)
    buf = b""
    while True:
        ready, _, _ = select.select([conn, raw], [], [], 5)
        if raw in ready:
            frame, addr = raw.recvfrom(65535)
            if addr[2] != PACKET_OUTGOING and not os.path.exists(gate):
                try:
                    conn.sendall(struct.pack(">I", len(frame)) + frame)
                except OSError:
                    break
        if conn in ready:
            data = conn.recv(65536)
            if not data:
                break
            buf += data
            while len(buf) >= 4:
                n = struct.unpack(">I", buf[:4])[0]
                if len(buf) < 4 + n:
                    break
                if not os.path.exists(gate):
                    raw.send(buf[4:4 + n])
                buf = buf[4 + n:]
    conn.close()
    print("relay: emulator disconnected", flush=True)
