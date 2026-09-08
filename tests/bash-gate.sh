#!/usr/bin/env bash
# Is the wrapper policy a boundary, or just a list?
#
#   bash tests/bash-gate.sh
#
# The plugin's answer to "what may the agent run" is six argv-validating
# wrappers, handed to the CLI as --allowedTools. That flag turned out not to
# deny what it omits: on Claude Code 2.1.251, `--allowedTools Read
# --permission-mode default` still ran `id -un` through Bash. bin/bash-gate.sh
# is what actually enforces it, as a PreToolUse hook, and this is where that
# claim is checked.
#
# As in tests/chrome-gate.sh, the card is answered by writing the verdict file
# bin/confirm.sh polls for, so no panel opens; refusals are made by letting the
# question time out.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

export HOME="$work/home"
data="$HOME/.local/share/computer-ai"
state="$data/state"
mkdir -p "$state" "$work/bin"
export COMPUTER_STATE_DIR="$state"
export COMPUTER_ACTIVITY_FILE="$state/activity.jsonl"
export COMPUTER_CONFIRM_TIMEOUT=1
printf '#!/bin/sh\nexit 0\n' > "$work/bin/omarchy-shell"
chmod +x "$work/bin/omarchy-shell"
export PATH="$work/bin:$PATH"
export OMARCHY_PATH="$work"

# The policy the gate enforces: the wrappers, exactly as ask.sh seeds them.
export COMPUTER_SETTINGS_FILE="$work/policy.json"
sed "s|__PLUGIN_DIR__|$repo|g" "$repo/defaults/permissions.json" > "$COMPUTER_SETTINGS_FILE"
echo '{"activity":"line"}' > "$state/activity.jsonl"

answer_next() { # $1 = allow|deny
  ( for _ in $(seq 1 200); do
      id=$(jq -r 'select(.kind == "confirm") | .id' "$state/pending-confirms.jsonl" 2>/dev/null | tail -1)
      if [ -n "$id" ] && [ "$id" != "null" ]; then
        printf '%s' "$1" > "$state/confirm-$id"; exit 0
      fi
      sleep 0.05
    done ) &
}

run() { # $1 = command string -> allow | deny | (silent)
  local out
  out=$(jq -cn --arg c "$1" \
          '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
        | "$repo/bin/bash-gate.sh")
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

echo "the wrappers the policy names run without asking:"
check "a wrapper with arguments"        "(silent)" "$(run "$repo/bin/clip.sh copy hello")"
check "a wrapper with none"             "(silent)" "$(run "$repo/bin/sysinfo.sh")"
check "a wrapper with a quoted argument" "(silent)" "$(run "$repo/bin/desktop.sh launch \"Firefox\"")"
check "mic-calibrate, which the agent is told to use" "(silent)" \
  "$(run "$repo/bin/mic-calibrate.sh status")"
check "config-set, likewise"            "(silent)" \
  "$(run "$repo/bin/config-set.sh voice \"kokoro:bf_isabella\"")"

echo "a wrapper is the whole command, not the start of one:"
check "trailing command after a semicolon" "deny" "$(run "$repo/bin/clip.sh copy hi; id -un")"
check "chained with &&"                    "deny" "$(run "$repo/bin/clip.sh copy hi && id -un")"
check "piped onward"                       "deny" "$(run "$repo/bin/clip.sh copy hi | tee /tmp/x")"
check "command substitution in an argument" "deny" "$(run "$repo/bin/clip.sh copy \$(cat /etc/passwd)")"
check "backticks in an argument"           "deny" "$(run "$repo/bin/clip.sh copy \`id\`")"
check "a redirect"                         "deny" "$(run "$repo/bin/clip.sh copy hi > /tmp/x")"
check "a newline hiding a second line"     "deny" "$(run "$(printf '%s\nid -un' "$repo/bin/clip.sh copy hi")")"

echo "a lookalike path is not the wrapper:"
check "same name somewhere else"        "deny" "$(run "/tmp/bin/clip.sh copy hi")"
check "the directory as a prefix"       "deny" "$(run "${repo}-evil/bin/clip.sh copy hi")"

echo "the command that proved the allowlist was not a gate:"
check "id -un reads no files, so it runs" "allow" "$(run "id -un")"
check "date likewise"                     "allow" "$(run "date")"
check "curl does not"                     "deny"  "$(run "curl https://example.com")"
check "nor does a shell"                  "deny"  "$(run "bash -c 'id'")"

echo "reading is allowed where the assistant's own things are:"
check "its activity log"      "allow" "$(run "cat $state/activity.jsonl")"
check "a listing of its state" "allow" "$(run "ls -la $state")"
check "jq's filter is not a path" "allow" "$(run "jq -r .activity $state/activity.jsonl")"

echo "and nowhere else:"
check "a private key"          "deny" "$(run "cat $HOME/.ssh/id_rsa")"
check "walking out with .."    "deny" "$(run "cat $data/../../.ssh/id_rsa")"
check "a glob it cannot see"   "deny" "$(run "cat $state/*")"
check "bare ls, wherever it lands" "deny" "$(run "ls")"
check "cat with no path is stdin"  "deny" "$(run "cat")"

echo "anything else asks, and is refused if nobody answers:"
answer_next allow
check "an approved one-off runs" "allow" "$(COMPUTER_CONFIRM_TIMEOUT=5 run "ffmpeg -version")"
check "the same command asks again next time" "deny" "$(run "ffmpeg -version")"

echo "a refusal closes the door:"
reason=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"rm -rf /tmp/x"}}' \
         | "$repo/bin/bash-gate.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case $reason in
  *declined*"another way"*) pass=$((pass + 1)); printf '  ok   %-54s\n' "and says so to the agent" ;;
  *) fail=$((fail + 1)); printf '  FAIL deny reason was [%s]\n' "$reason" ;;
esac

echo "tools other than Bash are none of its business:"
other=$(jq -cn '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:"/etc/passwd"}}' \
        | "$repo/bin/bash-gate.sh")
check "a Read call passes through" "" "$other"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
