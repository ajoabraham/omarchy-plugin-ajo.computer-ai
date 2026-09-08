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

# Whatever the user has said "never" to, said to this harness in its own
# words. --deny is honoured here (measured); --allow is not exhaustive.
deny_flags=()
while IFS= read -r rule; do
  [ -n "$rule" ] && deny_flags+=(--deny "$rule")
done < <(jq -r '.permissions.deny[]?' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

# The shell is denied outright here, and that is the whole permission story
# for this adapter.
#
# Measured on this machine: `grok -p … --allow Read` still ran `id -un`
# through the shell tool, exactly as Claude Code does — an allow list that
# does not constrain. Claude Code has a PreToolUse hook, which is where
# bin/bash-gate.sh puts the card; grok has no such seam, so there is nowhere
# to ask the user and no way to hold the wrapper policy up. What it does
# honour is --deny (also measured: `--deny Bash` blocked the same command).
#
# So this adapter answers and does not act, the same shape the ChatGPT one
# already has. Tier 1 through grok would be a list nothing enforces, which is
# the exact thing this plugin stopped shipping.
deny_flags+=(--deny "Bash")

prompt="$COMPUTER_INSTRUCTIONS

NOTE: In this harness the shell is closed to you — you can look things up and
answer, but not launch apps or change anything on the desktop. Say so if
asked to act, and mention that the Claude assistant can do it.

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
# The cap counts bytes, so it can land in the middle of a multi-byte
# character and leave half of one at the end of the reply — which the panel
# then decodes and hands to the speech synthesiser. Drop any such remnant.
scrub() {
  if command -v iconv >/dev/null 2>&1; then
    # iconv reports the dropped remnant as an error; the bytes before it are
    # already written, and a truncated tail is not a failed turn.
    iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
  else
    cat
  fi
}

bounded() {
  local rc
  "$@" 2>/dev/null | head -c "$max_answer_bytes" | scrub
  rc=${PIPESTATUS[0]}
  [ "$rc" = 141 ] && rc=0
  return "$rc"
}

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if bounded grok -p "$prompt" --resume "$COMPUTER_CONV_ID" "${model_flags[@]}" "${allow_flags[@]}" "${deny_flags[@]}"; then
    exit 0
  fi
fi
bounded grok -p "$prompt" --session-id "$COMPUTER_CONV_ID" "${model_flags[@]}" "${allow_flags[@]}" "${deny_flags[@]}"
