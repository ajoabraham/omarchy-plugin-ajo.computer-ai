#!/usr/bin/env bash
# Agent-callable: queue a permission request for the user to approve in the
# Computer panel. $1 = permission rule (e.g. "Bash(playerctl:*)"),
# $2 = short reason. The agent can only REQUEST — approval happens in the
# panel UI (apply-grant.sh), never here.
#
# Idempotent on purpose: a blocked tool call makes the agent re-request the
# same rule every turn until it is approved, so appending blindly would pile
# up identical cards — and since approval pops one line at a time, the user
# would press Allow, watch the card reappear, and think it failed. So skip a
# rule that is already queued, and skip one that is already granted (the
# agent just hasn't seen the new permission take effect yet).
set -eu
rule="$1"
reason="${2:-}"
state="$HOME/.local/share/computer-ai/state"
settings="$HOME/.local/share/computer-ai/claude-settings.json"
pending="$state/pending-grants.jsonl"
mkdir -p "$state"

# Already granted? A tool rule lives in permissions.allow; a Dir(/path) rule
# is stored stripped in permissions.additionalDirectories.
if [ -f "$settings" ]; then
  case "$rule" in
    "Dir("*")") probe=${rule#Dir(}; probe=${probe%)}; key='.permissions.additionalDirectories' ;;
    *)          probe="$rule";                        key='.permissions.allow' ;;
  esac
  if jq -e --arg v "$probe" "($key // []) | index(\$v)" "$settings" >/dev/null 2>&1; then
    echo "Already granted: $rule — no request needed; it should work now."
    exit 0
  fi
fi

# Already queued? Compare on the rule alone, so a reworded reason can't sneak
# a duplicate card past the check.
if [ -f "$pending" ] && jq -e --arg r "$rule" 'select(.rule == $r)' "$pending" >/dev/null 2>&1; then
  echo "Already awaiting approval: $rule — the card is in the Computer panel."
  exit 0
fi

jq -cn --arg rule "$rule" --arg reason "$reason" '{rule: $rule, reason: $reason}' \
  >> "$pending"
echo "Queued permission request: $rule — the user must approve it in the Computer panel; it applies from the next question."
