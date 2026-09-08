# Shared by the PreToolUse gates (bash-gate.sh, chrome-gate.sh). Sourced, not
# run: it holds the three things both gates must agree on, because the most
# important behaviour here — what a gate does when it cannot read the call —
# is not something that should exist in two copies and drift.
#
# Sourced with `|| exit 2`, so a missing or unreadable library blocks the tool
# call rather than letting the gate carry on without its own definitions.

# The hook's answer. Nothing else may reach stdout: a stray line is read as a
# malformed decision.
decide() { # $1 = allow|deny, $2 = reason shown to the agent
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: $d,
                           permissionDecisionReason: $r}}' 2>/dev/null && exit 0
  # No jq, so no decision object can be built. Exit 2 blocks the call whatever
  # is on stdout: a gate that cannot speak must not wave things through while
  # it works out how to.
  exit 2
}

# No decision: the tool goes through the ordinary permission flow, which is
# where the read-only tools are allowed.
silent() { exit 0; }

# The call, as JSON on stdin. Truncation is refusal, not abstention: a call
# too long to read is a call this cannot judge. `tool` is set to "!" when jq
# itself failed, so the caller can tell "not mine" from "unreadable".
read_call() {
  input=$(head -c 1000000)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null) || tool="!"
}

unreadable() { decide deny "The gate could not read this tool call, so it did not run."; }

# The card must not outlive the hook waiting for its answer. defaults/hooks.json
# gives each hook 180s; a card answered after Claude Code has given up is
# answered into nothing, and a hook that times out does not deny.
clamp_confirm_timeout() {
  case ${COMPUTER_CONFIRM_TIMEOUT:-120} in
    *[!0-9]*) export COMPUTER_CONFIRM_TIMEOUT=120 ;;
    *) [ "${COMPUTER_CONFIRM_TIMEOUT:-120}" -gt 150 ] && export COMPUTER_CONFIRM_TIMEOUT=150 ;;
  esac
  return 0
}
