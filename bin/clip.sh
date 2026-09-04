#!/usr/bin/env bash
# Put text on the clipboard, bounded, from stdin or one argument.
#
# Replaces `Bash(wl-copy:*)`, whose flags can set the primary selection, MIME
# type and persistence. Copy only — nothing here reads the clipboard back,
# so a page the agent is reading cannot use this to exfiltrate what you had
# copied a moment ago.
#
#   clip.sh <text>      |      <producer> | clip.sh
set -u

max="${COMPUTER_CLIP_MAX_BYTES:-100000}"
command -v wl-copy >/dev/null 2>&1 || { echo "clip: wl-copy is not installed" >&2; exit 127; }

if [ "$#" -gt 0 ]; then
  printf '%s' "$1" | head -c "$max" | wl-copy
else
  head -c "$max" | wl-copy
fi
