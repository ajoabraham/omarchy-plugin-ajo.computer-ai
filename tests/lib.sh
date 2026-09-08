# Shared scaffolding for the suites that drive the panel's gates.
#
# All three of these need the same things: a throwaway HOME so the caller's
# real state is never touched, a stubbed omarchy-shell so running the suite
# does not pop the panel open on someone's desktop, and a stand-in for the
# panel that answers the card bin/confirm.sh is waiting on. Written once here
# because the pending-confirm record has already changed shape once, and
# finding every copy of the code that reads it is exactly the cost of having
# copies.
#
# Sourced after `repo` and `work` are set.

pass=0; fail=0

# The panel opens itself when a card needs answering. Right in production,
# wrong in a test on someone's machine.
stub_panel() {
  mkdir -p "$work/bin"
  printf '#!/bin/sh\nexit 0\n' > "$work/bin/omarchy-shell"
  chmod +x "$work/bin/omarchy-shell"
  export PATH="$work/bin:$PATH"
  export OMARCHY_PATH="$work"
}

# A throwaway HOME, and the state directory the gates and confirm.sh share.
sandbox() {
  export HOME="$work/home"
  data="$HOME/.local/share/computer-ai"
  state="$data/state"
  mkdir -p "$state"
  export COMPUTER_STATE_DIR="$state"
  export COMPUTER_ACTIVITY_FILE="$state/activity.jsonl"
  stub_panel
}

# Stand in for the panel: answer the next card that appears, the way the panel
# does — by writing the verdict file confirm.sh is polling for. Three seconds
# is generous; a card reaches the queue file before the poll loop starts.
answer_next() { # $1 = allow|deny — sets answer_pid for the caller to reap
  ( for _ in $(seq 1 60); do
      id=$(jq -r 'select(.kind == "confirm") | .id' "$state/pending-confirms.jsonl" 2>/dev/null | tail -1)
      if [ -n "$id" ] && [ "$id" != "null" ]; then
        printf '%s' "$1" > "$state/confirm-$id"; exit 0
      fi
      sleep 0.05
    done ) >/dev/null 2>&1 &
  answer_pid=$!
}
# The redirect matters as much as the loop: this runs inside the command
# substitution that captures a gate's decision, and a background child holding
# that pipe open keeps `$(...)` waiting for it — three seconds per call, on
# every call, for a watcher that has usually already finished.

# One hook invocation: the JSON Claude Code would send, and the decision that
# comes back. Cards are answered `deny` unless the caller says otherwise —
# `card_answer=allow` to approve, `card_answer=none` to let it time out, which
# is a slower and different assertion worth making deliberately.
hook_decision() { # $1 = gate script, $2 = tool name, $3 = tool_input JSON
  local out
  answer_pid=""
  [ "${card_answer:-deny}" = none ] || answer_next "${card_answer:-deny}"
  out=$(jq -cn --arg t "$2" --argjson i "$3" \
          '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: $i}' | "$1")
  # A call that raised no card leaves its watcher polling for three seconds,
  # and that watcher will happily answer the NEXT call's card with the verdict
  # this one wanted. Reap it here: a stale "deny" from a silent read is
  # exactly how an approval test starts failing, intermittently, for reasons
  # that have nothing to do with the gate.
  [ -n "$answer_pid" ] && { kill "$answer_pid" 2>/dev/null; wait "$answer_pid" 2>/dev/null; }
  [ -n "$out" ] || { echo "(silent)"; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "(unparsable)"'
}

check() { # description, expected, actual
  if [ "$3" = "$2" ]; then
    pass=$((pass + 1)); printf '  ok   %-54s %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL %-54s got %s, wanted %s\n' "$1" "$3" "$2"
  fi
}

tally() {
  printf '\n  %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}
