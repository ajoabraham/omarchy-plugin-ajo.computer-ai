#!/usr/bin/env bash
# Claude Code harness adapter. --chrome attaches the Claude-in-Chrome
# extension relay so the agent can drive the user's real browser (needs the
# one-time automation grant in the extension; works headless because the CLI
# uses OAuth login). Permission policy maps to --allowedTools.
set -u
mapfile -t allow < <(jq -r '.permissions.allow[]' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if claude -p "$1" --resume "$COMPUTER_CONV_ID" \
    --append-system-prompt "$COMPUTER_INSTRUCTIONS" --output-format text \
    --chrome --allowedTools "${allow[@]}" "mcp__claude-in-chrome__.*" 2>/dev/null; then
    exit 0
  fi
fi
exec claude -p "$1" --session-id "$COMPUTER_CONV_ID" \
  --append-system-prompt "$COMPUTER_INSTRUCTIONS" --output-format text \
  --chrome --allowedTools "${allow[@]}" "mcp__claude-in-chrome__.*" 2>/dev/null
