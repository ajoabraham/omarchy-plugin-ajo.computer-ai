#!/usr/bin/env bash
# Tier-3 gate for the browser, as a Claude Code PreToolUse hook.
#
# The browser is the most authenticated surface on the machine and, at the
# same time, the place the agent's untrusted input comes from: a page it
# reads can carry instructions, and the tools that act on that page can send
# mail, buy things and change account settings in sessions the user is
# already logged into. Pre-approving them wholesale — which is what a bare
# `mcp__claude-in-chrome` rule or an `--allowedTools mcp__claude-in-chrome__.*`
# wildcard does — puts the richest capability on the machine outside the
# policy that governs everything else.
#
# So the same split the local wrappers use applies here. Reading a page is
# free. Acting on one blocks on bin/confirm.sh, the same card that gates
# `system reboot`, and the human answers it by key, click or voice.
#
# Claude Code runs this before every mcp__claude-in-chrome__* call and hands
# it the call as JSON on stdin. Printing a decision object approves or
# refuses the call; printing nothing leaves the normal permission flow to
# decide, which is what the read-only tools rely on.
set -u
umask 077

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${COMPUTER_STATE_DIR:-$HOME/.local/share/computer-ai/state}"

# stdout is the hook's answer and nothing else, so everything chatty in here
# is redirected. A stray line would be read as a malformed decision.
decide() { # $1 = allow|deny, $2 = reason shown to the agent
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: $d,
                           permissionDecisionReason: $r}}'
  exit 0
}

# No decision: the tool goes through the ordinary policy check, which is
# where the read-only browser tools are allowed.
silent() { exit 0; }

input=$(head -c 1000000)
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
case "$tool" in
  mcp__claude-in-chrome__*) verb=${tool#mcp__claude-in-chrome__} ;;
  *) silent ;;   # not ours to judge
esac

# Reading is not acting. These see the page and report it; everything they
# can do, the agent could already do by being told what the page said.
case "$verb" in
  tabs_context_mcp|list_connected_browsers|read_page|get_page_text|find|\
  read_console_messages|read_network_requests|shortcuts_list|select_browser|\
  switch_browser)
    silent ;;
esac

field() { printf '%s' "$input" | jq -rc --arg k "$1" '.tool_input[$k] // ""' 2>/dev/null; }
url=$(field url)

# The origin a URL really belongs to, or nothing if it is not a plain
# http(s) URL with a bare authority. `https://safe.example@evil.example/`
# is exactly why the authority has to end at a slash: anything with
# userinfo, credentials or an unusual shape is not scoped, it is asked
# about in full every time.
origin_of() {
  printf '%s' "$1" \
    | grep -oiE '^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/|$)' \
    | head -1 | sed 's|/$||' | tr '[:upper:]' '[:lower:]'
}

# What the card says. The value of a form field is deliberately not shown:
# it is as likely to be a password as a search term, and the card's text is
# written to the activity log.
describe() {
  case "$verb" in
    navigate)          label="browser: open a page";      detail="$url" ;;
    tabs_create_mcp)   label="browser: open a new tab";   detail="$url" ;;
    computer)          label="browser: act on the page"
                       detail="$(field action) $(field coordinate)" ;;
    form_input)        label="browser: fill in a field"
                       detail="$(field element_description) — $(field value | tr -d '\n' | wc -c) characters" ;;
    file_upload)       label="browser: upload a file";    detail="$(field file_path)" ;;
    upload_image)      label="browser: upload an image";  detail="$(field file_path)" ;;
    javascript_tool)   label="browser: run JavaScript in the page"
                       detail="$(field code | head -c 120)" ;;
    browser_batch)     label="browser: run a batch of actions"; detail="$(field actions | head -c 120)" ;;
    shortcuts_execute) label="browser: run a browser shortcut"; detail="$(field name)" ;;
    tabs_close_mcp)    label="browser: close a tab";      detail="$(field tab_id)" ;;
    gif_creator)       label="browser: record the screen"; detail="$(field output_path)" ;;
    *)                 label="browser: $verb";            detail="$url" ;;
  esac
  [ -n "$detail" ] || detail="in your logged-in browser session"
}
describe

# Approving a page to be opened approves reading it too, so navigation is
# scoped to its origin for the rest of THIS turn — one card per site rather
# than one per click. The scope dies with the turn: the file is named after
# the turn and ask.sh removes it on the way out, so nothing here survives
# into the next question the way a tier-2 grant would.
scope_file=""
turn=$(printf '%s' "${COMPUTER_TURN_ID:-}" | tr -dc 'A-Za-z0-9-' | head -c 64)
[ -n "$turn" ] && scope_file="$state_dir/chrome-scope-$turn"

scopeable=""
case "$verb" in
  navigate|tabs_create_mcp) scopeable=$(origin_of "$url") ;;
esac

if [ -n "$scopeable" ] && [ -n "$scope_file" ] && [ -f "$scope_file" ] \
   && grep -Fxq "$scopeable" "$scope_file" 2>/dev/null; then
  decide allow "You already approved $scopeable for this turn."
fi

if [ -n "$scopeable" ]; then
  detail="$scopeable — approving covers this site for this turn only"
fi

if "$plugin_dir/bin/confirm.sh" "$label" "$detail" >/dev/null 2>&1; then
  [ -n "$scopeable" ] && [ -n "$scope_file" ] &&
    printf '%s\n' "$scopeable" >> "$scope_file" 2>/dev/null
  decide allow "The user approved: $label."
fi

decide deny "The user declined: $label. Do not retry it, and do not look for another way to do the same thing; say so and move on."
