#!/usr/bin/env python
"""Synthesize speech with Kokoro TTS: kokoro-say.py <voice> <out.wav> <text>.

Runs inside the venv at ~/.local/share/computer/kokoro/venv (speak.sh invokes
it with that interpreter). Model files live next to the venv.
"""
import sys
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro

KOKORO_DIR = Path.home() / ".local/share/computer/kokoro"


def main() -> int:
    voice, out_path, text = sys.argv[1], sys.argv[2], sys.argv[3]
    kokoro = Kokoro(
        str(KOKORO_DIR / "kokoro-v1.0.onnx"),
        str(KOKORO_DIR / "voices-v1.0.bin"),
    )
    lang = "en-gb" if voice.startswith("b") else "en-us"
    samples, sample_rate = kokoro.create(text, voice=voice, speed=1.0, lang=lang)
    sf.write(out_path, samples, sample_rate)
    return 0


if __name__ == "__main__":
    sys.exit(main())
