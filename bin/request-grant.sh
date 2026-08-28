#!/usr/bin/env bash
# Agent-callable: queue a permission request for the user to approve in the
# Computer panel. $1 = permission rule (e.g. "Bash(playerctl:*)"),
# $2 = short reason. The agent can only REQUEST — approval happens in the
# panel UI (apply-grant.sh), never here.
set -eu
rule="$1"
reason="${2:-}"
state="$HOME/.local/share/computer-ai/state"
mkdir -p "$state"
jq -cn --arg rule "$rule" --arg reason "$reason" '{rule: $rule, reason: $reason}' \
  >> "$state/pending-grants.jsonl"
echo "Queued permission request: $rule — the user must approve it in the Computer panel; it applies from the next question."
