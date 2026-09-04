#!/usr/bin/env bash
# A desktop notification, with both fields bounded.
#
# Replaces `Bash(notify-send:*)`, which accepts option flags (icons, hints,
# actions, arbitrary lifetimes) and unbounded bodies — a fine channel for
# spamming or spoofing system UI. Here it is exactly a headline and a body,
# passed after `--` so neither can turn into a flag.
#
#   notify.sh <headline> [body]
set -u

head_txt=$(printf '%s' "${1:-}" | tr -d '\r' | head -c 120)
body_txt=$(printf '%s' "${2:-}" | tr -d '\r' | head -c 500)
[ -n "$head_txt" ] || { echo "usage: notify.sh <headline> [body]" >&2; exit 2; }
command -v notify-send >/dev/null 2>&1 || { echo "notify: notify-send is not installed" >&2; exit 127; }

exec notify-send -a "Computer" -- "$head_txt" "$body_txt"
