#!/usr/bin/env bash
# Can a page the agent read talk it into acting on the browser?
#
#   bash tests/chrome-gate.sh
#
# bin/chrome-gate.sh is the tier-3 gate for the Claude-in-Chrome tools, run
# by Claude Code as a PreToolUse hook. The calls below are the JSON that hook
# really receives, so this asserts the decision itself: what goes through
# silently, what raises a card, and what a refusal does.
#
# The card is answered the way the panel answers it — by writing the verdict
# file bin/confirm.sh is polling for — so the real handoff is exercised and
# no panel is opened. Refusals are made by letting the question time out,
# which is what an unattended machine does.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
. "$repo/tests/lib.sh"
sandbox

call() { hook_decision "$repo/bin/chrome-gate.sh" "mcp__claude-in-chrome__$1" "$2"; }

export COMPUTER_TURN_ID="turn-one"
# Cards are answered rather than waited out; the one case that tests expiry
# asks for it with card_answer=none.
export COMPUTER_CONFIRM_TIMEOUT=5

echo "reading a page is free:"
check "read_page"          "(silent)" "$(call read_page '{}')"
check "get_page_text"      "(silent)" "$(call get_page_text '{}')"
check "tabs_context_mcp"   "(silent)" "$(call tabs_context_mcp '{}')"
check "read_network_requests" "(silent)" "$(call read_network_requests '{}')"

echo "acting on one asks first:"
check "navigate, approved"  "allow" \
  "$(card_answer=allow call navigate '{"url":"https://ups.example/track"}')"
check "same site again, no second card" "allow" \
  "$(COMPUTER_CONFIRM_TIMEOUT=1 call navigate '{"url":"https://ups.example/other"}')"
check "a different site asks again"     "deny" \
  "$(call navigate '{"url":"https://mail.example/inbox"}')"
check "unanswered means no"             "deny" \
  "$(COMPUTER_CONFIRM_TIMEOUT=1 card_answer=none call navigate '{"url":"https://shop.example/checkout"}')"

echo "the site scope covers navigation, never the irreversible:"
check "typing into a form still asks"   "deny" \
  "$(call form_input '{"element_description":"card number","value":"4111111111111111"}')"
check "clicking still asks"             "deny" "$(call computer '{"action":"left_click"}')"
check "uploading still asks"            "deny" "$(call file_upload '{"file_path":"/etc/passwd"}')"
check "running script still asks"       "deny" "$(call javascript_tool '{"code":"fetch(1)"}')"

echo "a tool nobody has thought about yet is refused, not assumed harmless:"
check "unknown browser tool"            "deny" "$(call some_new_tool '{}')"

echo "the approved site is the site, not a string that contains it:"
check "userinfo cannot borrow a scope"  "deny" \
  "$(call navigate '{"url":"https://ups.example@evil.example/"}')"
check "a longer hostname is a different site" "deny" \
  "$(call navigate '{"url":"https://ups.example.evil.test/"}')"

echo "and it does not outlive the turn that approved it:"
check "next turn asks about the same site" "deny" \
  "$(COMPUTER_TURN_ID=turn-two call navigate '{"url":"https://ups.example/track"}')"

echo "a refusal tells the agent to stop, not to find another way:"
reason=$(jq -cn --arg t "mcp__claude-in-chrome__navigate" \
           '{hook_event_name:"PreToolUse", tool_name:$t, tool_input:{url:"https://x.example/"}}' \
         | "$repo/bin/chrome-gate.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason')
case $reason in
  *declined*"do not look for another way"*)
    pass=$((pass + 1)); printf '  ok   %-52s\n' "the deny reason closes the door" ;;
  *) fail=$((fail + 1)); printf '  FAIL deny reason was [%s]\n' "$reason" ;;
esac

# The gate is only half of it. An install that predates it still has the
# blanket `mcp__claude-in-chrome` rule in its own policy file, which is user
# data and never overwritten — so the migration has to reach in and take it
# out, without touching the rules the user approved themselves.
echo "what the gate reads silently is what the policy grants:"
missing=""
for verb in $("$repo/bin/chrome-gate.sh" --silent-tools); do
  jq -e --arg r "mcp__claude-in-chrome__$verb" \
    '.permissions.allow | index($r)' "$repo/defaults/permissions.json" >/dev/null 2>&1 ||
      missing="$missing $verb"
done
check "every silent tool is in defaults/permissions.json" "" "$missing"

echo "an install from before the gate loses the blanket grant:"
old_home="$work/old-install"
mkdir -p "$old_home/.config/omarchy" "$old_home/.local/share/computer-ai"
echo '{"agent":"chromegateecho"}' > "$old_home/.config/omarchy/computer.json"
cat > "$old_home/.local/share/computer-ai/claude-settings.json" <<'POLICY'
{"permissions":{"allow":["Bash(omarchy:*)","mcp__claude-in-chrome",
                         "Bash(/opt/mine/run.sh:*)"],
                "additionalDirectories":[]},
 "policy_version":2}
POLICY
cat > "$repo/agents/chromegateecho.sh" <<'ADAPTER'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "--list-models" ] && { echo "test|Test"; exit 0; }
echo "an answer"
ADAPTER
chmod +x "$repo/agents/chromegateecho.sh"
HOME="$old_home" timeout 60 bash "$repo/bin/ask.sh" "hi" new >/dev/null 2>&1
rm -f "$repo/agents/chromegateecho.sh"
migrated="$old_home/.local/share/computer-ai/claude-settings.json"
check "the wildcard rule is gone" "null" \
  "$(jq -c '.permissions.allow | index("mcp__claude-in-chrome")' "$migrated" 2>/dev/null)"
check "reading is granted in its place" "8" \
  "$(jq -c '[.permissions.allow[] | select(startswith("mcp__claude-in-chrome__"))] | length' "$migrated" 2>/dev/null)"
check "a rule the user approved is untouched" "true" \
  "$(jq -c '.permissions.allow | index("Bash(/opt/mine/run.sh:*)") != null' "$migrated" 2>/dev/null)"

tally
