#!/usr/bin/env bash
# Grok CLI harness adapter. Permission policy maps to repeated --allow flags
# (grok accepts claude-code-style rules); instructions are prepended to the
# prompt since grok has no system-prompt flag.
set -u

# Live list from the CLI (first line = its default/latest); static fallback.
if [ "${1:-}" = "--list-models" ]; then
  grok models 2>/dev/null | awk '
    /^[[:space:]]+[*-][[:space:]]/ {
      name=$2
      if ($0 ~ /default/) print name "|" name " (default)"
      else print name "|" name
    }' | grep . || echo "default|Default (latest)"
  exit 0
fi

model_flags=()
if [ -n "${COMPUTER_MODEL:-}" ] && [ "$COMPUTER_MODEL" != "default" ]; then
  model_flags=(-m "$COMPUTER_MODEL")
fi

allow_flags=()
while IFS= read -r rule; do
  [ -n "$rule" ] && allow_flags+=(--allow "$rule")
done < <(jq -r '.permissions.allow[]' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

prompt="$COMPUTER_INSTRUCTIONS

Request: $1"

# The reply is capped here, at the producer. The panel collects a turn's
# stdout to EOF and clamps only afterwards, so an agent CLI that never
# stopped talking would sit in the shell's memory in full — and that shell
# runs the bar.
max_answer_bytes="${COMPUTER_MAX_ANSWER_BYTES:-65536}"
case "$max_answer_bytes" in ''|*[!0-9]*) max_answer_bytes=65536 ;; esac

# Being cut off by the cap is not a failed turn: grok dies of SIGPIPE having
# already said more than will ever be spoken, and the resume branch below
# must not read that as "resume failed" and ask the whole question again.
bounded() {
  local rc
  "$@" 2>/dev/null | head -c "$max_answer_bytes"
  rc=${PIPESTATUS[0]}
  [ "$rc" = 141 ] && rc=0
  return "$rc"
}

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if bounded grok -p "$prompt" --resume "$COMPUTER_CONV_ID" "${model_flags[@]}" "${allow_flags[@]}"; then
    exit 0
  fi
fi
bounded grok -p "$prompt" --session-id "$COMPUTER_CONV_ID" "${model_flags[@]}" "${allow_flags[@]}"
