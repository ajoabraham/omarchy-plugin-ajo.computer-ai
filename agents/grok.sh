#!/usr/bin/env bash
# Grok CLI harness adapter. Permission policy maps to repeated --allow flags
# (grok accepts claude-code-style rules); instructions are prepended to the
# prompt since grok has no system-prompt flag.
set -u
allow_flags=()
while IFS= read -r rule; do
  [ -n "$rule" ] && allow_flags+=(--allow "$rule")
done < <(jq -r '.permissions.allow[]' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

prompt="$COMPUTER_INSTRUCTIONS

Request: $1"

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if grok -p "$prompt" --resume "$COMPUTER_CONV_ID" "${allow_flags[@]}" 2>/dev/null; then
    exit 0
  fi
fi
exec grok -p "$prompt" --session-id "$COMPUTER_CONV_ID" "${allow_flags[@]}" 2>/dev/null
