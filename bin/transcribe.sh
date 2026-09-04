#!/usr/bin/env bash
# Transcribe a recording with Voxtype. The input is raw s16le 16kHz mono PCM
# from record.sh; voxtype wants WAV, so wrap it first.
# Model: `stt_model` in ~/.config/omarchy/computer.json, defaulting to
# tiny.en (~2x faster than base.en on CPU with near-identical accuracy for
# short commands). If the fast model hears nothing, retry once with base.en.
# Tip: after `sudo voxtype setup gpu --enable` (Vulkan), base.en becomes
# fast too — set stt_model to base.en then.
# Voxtype mixes progress noise into stdout; the transcript is the last
# non-empty line once ANSI codes are stripped.
set -u
umask 077
cfg="$HOME/.config/omarchy/computer.json"
model=$(jq -r '.stt_model // "tiny.en"' "$cfg" 2>/dev/null)

raw="${1:-}"
[ -n "$raw" ] || { echo "usage: transcribe.sh <raw-pcm-file>" >&2; exit 2; }

# The panel names each capture unpredictably, which is what keeps a shared
# directory from being a problem while it is being written. Afterwards
# exactly one capture is kept, under a fixed name beside it, because
# mic-calibrate.sh measures the turn the user just spoke — so this is a
# rename, not a copy, and never a second file left lying around.
keep="$(dirname "$raw")/computer-ai-last.raw"

wav=$(mktemp --suffix=.wav)
# The converted wav is scratch and goes unconditionally; the capture is
# retired to $keep on the way out, replacing the previous turn's.
cleanup() {
  rm -f "$wav"
  if [ -f "$raw" ]; then
    # Belt and braces: record.sh creates this under umask 077, but the file
    # that survives a turn is microphone audio and gets an explicit mode.
    chmod 600 "$raw" 2>/dev/null || true
    mv -f "$raw" "$keep" 2>/dev/null || true
  fi
}
trap cleanup EXIT
ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$raw" -y "$wav" </dev/null || exit 1

run_stt() {
  voxtype --model "$1" transcribe "$wav" 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' \
    | grep -vE '^(Loading audio file|Audio format|Processing )' \
    | awk 'NF { last = $0 } END { if (last) print last }'
}

text=$(run_stt "$model")
if [ -z "$text" ] && [ "$model" != "base.en" ]; then
  text=$(run_stt "base.en")
fi
[ -n "$text" ] && printf '%s\n' "$text"
