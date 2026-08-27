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
cfg="$HOME/.config/omarchy/computer.json"
model=$(jq -r '.stt_model // "tiny.en"' "$cfg" 2>/dev/null)

wav=$(mktemp --suffix=.wav)
trap 'rm -f "$wav"' EXIT
ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$1" -y "$wav" </dev/null || exit 1

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
