#!/usr/bin/env bash
# Play a microphone capture back, so "was it me or was it the recording?"
# is a question with an answer.
#
#   play-capture.sh [file]     default: the last turn's capture
#
# The panel's waveform tells you whether audio arrived and how loud it was;
# this tells you what it actually sounded like. Between them, a bad
# transcription stops being a mystery: silence, clipping, a fan, or a
# perfectly clear sentence the model simply got wrong.
#
# Captures are raw s16le 16 kHz mono (see record.sh), which nothing plays
# directly, so it is wrapped as WAV first.
set -u
umask 077

rec_dir="${XDG_RUNTIME_DIR:-$HOME/.local/share/computer-ai/state}"
pcm="${1:-$rec_dir/computer-ai-last.raw}"

# Only this plugin's own captures, in the directory it writes them to —
# otherwise this is a way to play any file on the machine out loud.
case "$pcm" in
  "$rec_dir"/computer-ai-*) ;;
  *) echo "play-capture: only this plugin's captures in $rec_dir can be played" >&2; exit 2 ;;
esac
[ -s "$pcm" ] || { echo "play-capture: no recording yet — speak a turn first" >&2; exit 1; }

command -v ffmpeg >/dev/null 2>&1 || { echo "play-capture: ffmpeg is not installed" >&2; exit 127; }
command -v pw-play >/dev/null 2>&1 || { echo "play-capture: pw-play is not installed" >&2; exit 127; }

wav=$(mktemp "$rec_dir/computer-ai-play.XXXXXX.wav") || exit 2
trap 'rm -f "$wav"' EXIT

ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$pcm" -y "$wav" </dev/null || exit 1

# Reported for the panel's playhead, and useful on its own: a capture that
# is a fifth of a second long explains a lot.
dur=$(awk -v b="$(wc -c < "$pcm")" 'BEGIN { printf "%.1f", b / 32000 }')
echo "Playing back ${dur}s of the last capture."
exec pw-play "$wav"
