#!/usr/bin/env bash
# Panel-invoked: resolve the FIRST pending permission request. $1 = allow|deny.
# "allow" merges the rule into the voice assistant's settings file (used by
# claude via --settings and mined for grok's --allow flags); either way the
# request is removed from the queue.
set -eu
verdict="$1"
state="$HOME/.local/share/computer/state"
pending="$state/pending-grants.jsonl"
settings="$HOME/.local/share/computer/claude-settings.json"
[ -s "$pending" ] || exit 0
rule=$(head -n1 "$pending" | jq -r .rule)
if [ "$verdict" = "allow" ] && [ -n "$rule" ]; then
  tmp=$(mktemp)
  jq --arg rule "$rule" '.permissions.allow += [$rule] | .permissions.allow |= unique' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
fi
sed -i '1d' "$pending"
