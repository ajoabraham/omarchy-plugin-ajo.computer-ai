#!/usr/bin/env bash
# Set one key in ~/.config/omarchy/computer.json. $1 = key, $2 = JSON value
# (so strings arrive pre-quoted: config-set.sh voice '"en_GB-alan-medium"').
set -eu
umask 077

# A grammar, like the other pre-approved wrappers have — because this one is
# pre-approved too, and "set any key to any value" is not a small permission
# in a file that decides what runs. `agent` names the adapter script the next
# turn executes, so an unchecked key here would be a way to point the turn at
# an arbitrary executable without ever raising a card.
usage() { echo "usage: config-set.sh <key> <json-value>" >&2; exit 2; }
[ "$#" = 2 ] || usage
key=$1; val=$2

# Each key says what shape its value may take. A bare "is it a string?" is
# not enough for `agent`: that value becomes the name of the adapter script
# the next turn executes, so it has to be a bare name — no slash, no dot, no
# semicolon — or this wrapper is a way to point a turn at any executable on
# the machine without ever raising a card.
case $key in
  agent)                            shape='"[A-Za-z0-9_-]\+"' ;;
  voice|stt_model|model_*)          shape='"[A-Za-z0-9._:+-]\+"' ;;
  tone_enabled|voice_approval)      shape='true\|false' ;;
  mic_threshold_db|mic_end_silence_ms) shape='-\?[0-9]\+' ;;
  *) echo "config-set.sh: $key is not a key this may set" >&2; exit 2 ;;
esac
printf '%s' "$val" | grep -qx -- "$shape" || {
  echo "config-set.sh: $val is not a value $key may take" >&2; exit 2; }

cfg="$HOME/.config/omarchy/computer.json"
[ -f "$cfg" ] || printf '{}\n' > "$cfg"
# Staged beside the file it replaces, so the swap is an atomic rename on the
# same filesystem rather than a copy from /tmp.
tmp=$(mktemp "$(dirname "$cfg")/.computer.XXXXXX")
if jq --arg k "$key" --argjson v "$val" '.[$k] = $v' "$cfg" > "$tmp"; then
  mv -f "$tmp" "$cfg"
else
  rm -f "$tmp"
  exit 1
fi
