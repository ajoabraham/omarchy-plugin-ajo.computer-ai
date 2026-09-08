#!/usr/bin/env bash
# Auto mode: run whatever the agent asks the shell to run, without a card.
#
#   auto-mode.sh get         → on | off
#   auto-mode.sh set on|off
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
mkdir -p "$(dirname "$cfg")"
[ -f "$cfg" ] || printf '{}\n' > "$cfg"

case "${1:-get}" in
  get)
    jq -r 'if .auto_mode == true then "on" else "off" end' "$cfg" 2>/dev/null || echo off
    ;;
  set)
    case "${2:-}" in
      on)  want=true ;;
      off) want=false ;;
      *) echo "usage: auto-mode.sh set on|off" >&2; exit 2 ;;
    esac
    # Staged beside the file it replaces, so the swap is an atomic rename on
    # the same filesystem — the same handling every other durable setting gets.
    tmp=$(mktemp "$(dirname "$cfg")/.computer.XXXXXX")
    if jq --argjson v "$want" '.auto_mode = $v' "$cfg" > "$tmp"; then
      mv -f "$tmp" "$cfg"
      echo "auto mode -> $2"
    else
      rm -f "$tmp"; exit 1
    fi
    ;;
  *) echo "usage: auto-mode.sh [get | set on|off]" >&2; exit 2 ;;
esac
