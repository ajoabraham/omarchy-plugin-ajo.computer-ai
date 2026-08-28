#!/usr/bin/env python
"""Persistent Kokoro TTS daemon: loads the model once and serves synthesis
requests over a Unix socket, cutting ~1.5-2s of per-reply model-load latency.

Protocol: one JSON line per connection — {"text": ..., "voice": ..., "out": path}
— the server writes a WAV to `out` and replies "ok\n" (or "err <msg>\n").
Exits after 10 minutes idle; speak.sh respawns it on demand.
"""
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro

KOKORO_DIR = Path.home() / ".local/share/computer-ai/kokoro"
SOCK_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "computer-ai-kokoro.sock"
IDLE_EXIT_SECONDS = 600

last_activity = time.monotonic()


def idle_watchdog() -> None:
    while True:
        time.sleep(30)
        if time.monotonic() - last_activity > IDLE_EXIT_SECONDS:
            try:
                SOCK_PATH.unlink(missing_ok=True)
            finally:
                os._exit(0)


def main() -> int:
    global last_activity
    kokoro = Kokoro(
        str(KOKORO_DIR / "kokoro-v1.0.onnx"),
        str(KOKORO_DIR / "voices-v1.0.bin"),
    )

    SOCK_PATH.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(SOCK_PATH))
    os.chmod(SOCK_PATH, 0o600)
    server.listen(4)

    threading.Thread(target=idle_watchdog, daemon=True).start()

    while True:
        conn, _ = server.accept()
        last_activity = time.monotonic()
        try:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            req = json.loads(data.decode())
            voice = req.get("voice", "af_heart")
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, rate = kokoro.create(
                req["text"], voice=voice, speed=1.0, lang=lang
            )
            sf.write(req["out"], samples, rate)
            conn.sendall(b"ok\n")
        except Exception as exc:  # noqa: BLE001 — report, keep serving
            try:
                conn.sendall(f"err {exc}\n".encode())
            except OSError:
                pass
        finally:
            conn.close()
            last_activity = time.monotonic()


if __name__ == "__main__":
    sys.exit(main())
