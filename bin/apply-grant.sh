#!/usr/bin/env bash
# Panel-invoked: resolve the FIRST pending permission request. $1 = allow|deny.
# "allow" merges the rule into the voice assistant's settings file (mined by
# the adapters for their harness's flags); either way the request is removed
# from the queue.
#
# Two kinds of rule: 'Dir(/path)' widens the agent's working directories
# (claude's --add-dir), everything else is a tool rule and goes in the
# allowlist. The agent can only queue requests — this is the approval gate.
set -eu
umask 077
verdict="$1"
state="$HOME/.local/share/computer-ai/state"
pending="$state/pending-grants.jsonl"
settings="$HOME/.local/share/computer-ai/claude-settings.json"
[ -s "$pending" ] || exit 0
rule=$(head -n1 "$pending" | jq -r .rule)
if [ "$verdict" = "allow" ] && [ -n "$rule" ]; then
  case "$rule" in
    "Dir("*")")
      dir=${rule#Dir(}; dir=${dir%)}
      filter='.permissions.additionalDirectories =
        (((.permissions.additionalDirectories // []) + [$v]) | unique)'
      ;;
    *)
      dir="$rule"
      filter='.permissions.allow = (((.permissions.allow // []) + [$v]) | unique)'
      ;;
  esac
  if [ -n "$dir" ]; then
    tmp=$(mktemp "$state/.settings.XXXXXX")
    if jq --arg v "$dir" "$filter" "$settings" > "$tmp"; then
      chmod 600 "$tmp"
      mv -f "$tmp" "$settings"
    else
      rm -f "$tmp"
      exit 1
    fi
  fi
fi
# Drop EVERY queued entry for this rule, not just the first line. The agent
# re-requests each turn until approved, so the same rule can be queued several
# times; clearing only line 1 would make the card reappear after one Allow and
# read as if the keypress did nothing.
tmp=$(mktemp "$state/.pending.XXXXXX")
jq -c --arg r "$rule" 'select(.rule != $r)' "$pending" > "$tmp" 2>/dev/null || : > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$pending"
