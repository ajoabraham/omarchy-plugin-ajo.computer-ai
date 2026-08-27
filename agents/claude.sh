#!/usr/bin/env bash
# Claude Code harness adapter. --chrome attaches the Claude-in-Chrome
# extension relay so the agent can drive the user's real browser (needs the
# one-time automation grant in the extension; works headless because the CLI
# uses OAuth login). Permission policy maps to --allowedTools.
set -u

# First line is the recommended latest/best (used as the default model).
if [ "${1:-}" = "--list-models" ]; then
  printf '%s\n' \
    "claude-fable-5|Fable 5" \
    "claude-opus-5|Opus 5" \
    "claude-sonnet-5|Sonnet 5" \
    "claude-haiku-4-5-20251001|Haiku 4.5"
  exit 0
fi

model_flags=()
if [ -n "${COMPUTER_MODEL:-}" ] && [ "$COMPUTER_MODEL" != "default" ]; then
  model_flags=(--model "$COMPUTER_MODEL")
fi

mapfile -t allow < <(jq -r '.permissions.allow[]' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if claude -p "$1" --resume "$COMPUTER_CONV_ID" "${model_flags[@]}" \
    --append-system-prompt "$COMPUTER_INSTRUCTIONS" --output-format text \
    --chrome --allowedTools "${allow[@]}" "mcp__claude-in-chrome__.*" 2>/dev/null; then
    exit 0
  fi
fi
exec claude -p "$1" --session-id "$COMPUTER_CONV_ID" "${model_flags[@]}" \
  --append-system-prompt "$COMPUTER_INSTRUCTIONS" --output-format text \
  --chrome --allowedTools "${allow[@]}" "mcp__claude-in-chrome__.*" 2>/dev/null
