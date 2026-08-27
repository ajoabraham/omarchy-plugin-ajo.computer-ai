#!/usr/bin/env python
"""Tiny stdlib-only client for kokoro-daemon.py (fast to start — no ML imports).

Usage:
  kokoro-client.py --ping <socket>                 # 0 if the daemon accepts
  kokoro-client.py <socket> <voice> <out.wav> <text>
"""
import json
import socket
import sys


def main() -> int:
    if sys.argv[1] == "--ping":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(sys.argv[2])
        s.close()
        return 0

    sock_path, voice, out, text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(sock_path)
    s.sendall((json.dumps({"text": text, "voice": voice, "out": out}) + "\n").encode())
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        reply += chunk
    s.close()
    return 0 if reply.startswith(b"ok") else 1


if __name__ == "__main__":
    sys.exit(main())
