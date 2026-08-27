#!/usr/bin/env bash
# Transcribe a recording with Voxtype's whisper model. The input is raw
# s16le 16kHz mono PCM from record.sh; voxtype wants WAV, so wrap it first.
# Voxtype mixes progress noise into stdout; the transcript is the last
# non-empty line once ANSI codes are stripped.
set -u
wav=$(mktemp --suffix=.wav)
trap 'rm -f "$wav"' EXIT
ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$1" -y "$wav" </dev/null || exit 1
voxtype transcribe "$wav" 2>/dev/null \
  | sed -e 's/\x1b\[[0-9;]*m//g' \
  | grep -vE '^(Loading audio file|Audio format|Processing )' \
  | awk 'NF { last = $0 } END { if (last) print last }'
