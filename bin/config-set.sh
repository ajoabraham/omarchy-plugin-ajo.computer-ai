#!/usr/bin/env bash
# Set one key in ~/.config/omarchy/computer.json. $1 = key, $2 = JSON value
# (so strings arrive pre-quoted: config-set.sh voice '"en_GB-alan-medium"').
set -eu
cfg="$HOME/.config/omarchy/computer.json"
[ -f "$cfg" ] || printf '{}\n' > "$cfg"
tmp=$(mktemp)
jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
