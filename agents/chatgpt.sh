#!/usr/bin/env bash
# ChatGPT harness adapter, via OpenAI's Codex CLI (`codex exec`).
#
# Differences from the other harnesses:
# - Codex mints its own session ids, so continuity uses `resume --last`
#   (the most recent codex exec session) rather than COMPUTER_CONV_ID.
# - Codex's permission model is sandbox-based, not rule-based; this adapter
#   runs read-only, so ChatGPT answers questions and reads the system but
#   does not take desktop actions.
set -u
out=$(mktemp)
trap 'rm -f "$out"' EXIT

prompt="$COMPUTER_INSTRUCTIONS

NOTE: In this harness you run with a read-only sandbox — you can look things
up and read, but not launch apps or change anything. Say so if asked to act.

Request: $1"

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  if codex exec resume --last - -s read-only --skip-git-repo-check -o "$out" \
    <<<"Request: $1" >/dev/null 2>&1 && [ -s "$out" ]; then
    cat "$out"
    exit 0
  fi
fi
codex exec - -s read-only --skip-git-repo-check -o "$out" <<<"$prompt" >/dev/null 2>&1
if [ ! -s "$out" ]; then
  # Speak the failure instead of dying silently — the usual cause is auth.
  echo "The ChatGPT harness couldn't answer. It's usually not signed in — run codex login in a terminal, then try me again."
  exit 0
fi
cat "$out"
