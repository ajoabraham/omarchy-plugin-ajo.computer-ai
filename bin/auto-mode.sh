#!/usr/bin/env bash
# Auto mode: run whatever the agent asks the shell to run, without a card.
#
#   auto-mode.sh get [shell|browser]         → on | off
#   auto-mode.sh set [shell|browser] on|off
#
# Two scopes, because they are two different risks. "shell" is every command
# the agent runs; "browser" is every action it takes in your logged-in
# Chromium. Saying yes to one is not saying yes to the other, and the card
# that offers each says which it is.
#
# This is the one switch that turns the tier-1 gate off, so who may throw it
# matters more than what it does. It is deliberately NOT one of the
# pre-approved wrappers, and `auto_mode` is deliberately not a key
# config-set.sh will write: config-set.sh is tier 1, so if it could write
# this key the agent could grant itself auto mode with a single pre-approved
# command, and a gate that the thing being gated can open is not a gate.
#
# The two things that call this are the panel — a human pressing a switch in
# Settings, or "Always allow" on a card — and bin/bash-gate.sh, which reads
# it. Neither route goes through the Bash tool.
set -eu
umask 077

cfg="$HOME/.config/omarchy/computer.json"

# Scope is optional and defaults to shell, so the original two-word form
# (`get`, `set on`) still means what it always meant.
verb=${1:-get}
scope=shell
value=${2:-}
case "${2:-}" in
  shell|browser) scope=$2; value=${3:-} ;;
esac
case "$scope" in
  shell)   key=auto_mode ;;
  browser) key=auto_mode_browser ;;
esac

case "$verb" in
  get)
    # bin/bash-gate.sh asks this before every single command the agent runs,
    # so the read path does no more than read: no mkdir, no seeding, and a
    # missing file simply means off.
    jq -r --arg k "$key" 'if .[$k] == true then "on" else "off" end' "$cfg" 2>/dev/null || echo off
    ;;
  set)
    case "$value" in
      on)  want=true ;;
      off) want=false ;;
      *) echo "usage: auto-mode.sh set [shell|browser] on|off" >&2; exit 2 ;;
    esac
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || printf '{}\n' > "$cfg"
    # Staged beside the file it replaces, so the swap is an atomic rename on
    # the same filesystem — the same handling every other durable setting gets.
    tmp=$(mktemp "$(dirname "$cfg")/.computer.XXXXXX")
    if jq --arg k "$key" --argjson v "$want" '.[$k] = $v' "$cfg" > "$tmp"; then
      mv -f "$tmp" "$cfg"
      echo "$scope auto mode -> $value"
    else
      rm -f "$tmp"; exit 1
    fi
    ;;
  *) echo "usage: auto-mode.sh [get|set] [shell|browser] [on|off]" >&2; exit 2 ;;
esac
