#!/usr/bin/env bash
# Set one key in ~/.config/omarchy/computer.json. $1 = key, $2 = JSON value
# (so strings arrive pre-quoted: config-set.sh voice '"en_GB-alan-medium"').
set -eu
umask 077
cfg="$HOME/.config/omarchy/computer.json"
[ -f "$cfg" ] || printf '{}\n' > "$cfg"
# Staged beside the file it replaces, so the swap is an atomic rename on the
# same filesystem rather than a copy from /tmp.
tmp=$(mktemp "$(dirname "$cfg")/.computer.XXXXXX")
if jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$cfg" > "$tmp"; then
  mv -f "$tmp" "$cfg"
else
  rm -f "$tmp"
  exit 1
fi
