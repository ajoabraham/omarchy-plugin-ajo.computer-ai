#!/usr/bin/env bash
# Ask the configured assistant to answer — or act. The question is $1; $2 is
# the turn mode: "new" when the panel was just opened, "follow" for later
# turns in the same panel session.
#
# Agents are pluggable: every agents/<name>.sh is a harness adapter, and the
# panel's Assistant dropdown lists them automatically. An adapter receives
# the question as $1 plus the COMPUTER_* environment (instructions, settings
# file, conversation id, whether the conversation already started), prints
# the answer on stdout, and exits 0 on success. See agents/README for the
# contract; adding an agent is just dropping a script in agents/.
#
# Turns thread into one agent conversation per panel session, with a grace
# window: re-opening the panel within 10 minutes resumes the previous
# conversation. Switching assistants starts fresh. The assistant can queue a
# reset via bin/new-conversation.sh (flag consumed here, next turn).
#
# Permission policy lives in the settings file below; the panel's grant flow
# (request-grant.sh / apply-grant.sh) appends to it with user approval.
#
# Adapters that can report progress append JSONL activity lines to
# COMPUTER_ACTIVITY_FILE while they work; the panel tails it live (Ctrl+I).
# It is truncated here, so the file always holds exactly this turn.
set -u
# Everything this turn writes — transcripts in the activity log, the
# conversation pointer, the permission policy — is private to the user.
umask 077
plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfg="$HOME/.config/omarchy/computer.json"
data_dir="$HOME/.local/share/computer-ai"
mem_dir="$data_dir/memory"
state_dir="$data_dir/state"
settings_file="$data_dir/claude-settings.json"
export PATH="$HOME/.local/share/mise/shims:$HOME/.grok/bin:$HOME/.local/bin:$PATH"
cd "$HOME"

mkdir -p "$mem_dir" "$state_dir"
chmod 700 "$data_dir" "$mem_dir" "$state_dir" 2>/dev/null || true
[ -f "$mem_dir/MEMORY.md" ] || printf '# Computer memory index\n' > "$mem_dir/MEMORY.md"
# First run: seed the user's permission policy from the shipped defaults
# (never overwritten afterwards — apply-grant.sh appends user-approved rules
# to the live copy, which is user data and stays out of the repo).
if [ ! -f "$settings_file" ]; then
  sed "s|__PLUGIN_DIR__|$plugin_dir|g" "$plugin_dir/defaults/permissions.json" > "$settings_file"
fi
chmod 600 "$settings_file" 2>/dev/null || true

# --- policy migration ------------------------------------------------------
#
# The live policy is user data and is never overwritten, so an install from
# before the wrappers existed would keep its pre-approved `Bash(omarchy:*)`,
# `Bash(uwsm-app:*)` and `Bash(hyprctl:*)` for good — and each of those is a
# general-purpose launcher, which makes every other rule in the file
# decorative. Retire them once, adding the narrow wrapper rules that replace
# them, and stamp the file so this runs exactly once per install.
policy_version=2
have_version=$(jq -r '.policy_version // 0' "$settings_file" 2>/dev/null || echo 0)
case "$have_version" in ''|*[!0-9]*) have_version=0 ;; esac
if [ "$have_version" -lt "$policy_version" ]; then
  retired='["Bash(omarchy:*)","Bash(uwsm-app:*)","Bash(hyprctl:*)","Bash(xdg-open:*)",
            "Bash(wpctl:*)","Bash(playerctl:*)","Bash(notify-send:*)","Bash(wl-copy:*)",
            "Bash(df:*)","Bash(free:*)","Bash(sensors:*)","Bash(pacman -Q:*)",
            "Bash(systemctl --user status:*)"]'
  added=$(jq -r --arg d "$plugin_dir" '
    ["omarchy-do","desktop","media","notify","clip","sysinfo"]
    | map("Bash(" + $d + "/bin/" + . + ".sh:*)")' <<<'null')
  tmp=$(mktemp "$state_dir/.settings.XXXXXX")
  if jq --argjson retire "$retired" --argjson add "$added" --argjson v "$policy_version" '
        .permissions.allow = (((.permissions.allow // []) - $retire) + $add | unique)
        | .policy_version = $v' "$settings_file" > "$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$settings_file"
  else
    rm -f "$tmp"
  fi
fi
activity_file="$state_dir/activity.jsonl"
: > "$activity_file"

memory=$(head -c 4000 "$mem_dir/MEMORY.md" 2>/dev/null)
now=$(date '+%A, %B %d %Y, %H:%M')

instructions="You are 'Computer', a voice assistant on an Omarchy Linux desktop \
(Arch + Hyprland), in the spirit of the Star Trek ship's computer. The user's \
words arrive via speech-to-text, so tolerate small transcription errors. \
The current date and time: $now.

You may OPERATE this computer with your tools when asked. Every desktop
action goes through one of the wrapper commands below — they are the only
pre-approved commands, and each one validates its own arguments, so a
mistyped or invented flag is refused rather than run. Do not try to reach
around them with omarchy, hyprctl, uwsm-app or xdg-open directly: those are
not approved, and asking for them will be denied.
- Apps and links:
  - $plugin_dir/bin/desktop.sh launch <app>  (terminal, browser, editor,
    files, music, spotify, signal, slack, discord, calendar, settings...)
    Any other app name still works but asks the user to confirm first.
  - $plugin_dir/bin/desktop.sh launch browser <https url>
  - $plugin_dir/bin/desktop.sh open-url <https url>   (http/https only)
- The omarchy command center, through $plugin_dir/bin/omarchy-do.sh <verb...>:
  - Look and feel: 'omarchy-do.sh theme list', 'omarchy-do.sh theme set <name>',
    'omarchy-do.sh theme bg next', 'omarchy-do.sh font set <name>',
    'omarchy-do.sh toggle nightlight', 'omarchy-do.sh display text size <n>'.
  - Screen: 'omarchy-do.sh screenshot', 'omarchy-do.sh capture screenshot region|window|fullscreen copy|save',
    'omarchy-do.sh capture text' (OCR a region), 'omarchy-do.sh capture screenrecording'.
  - Comfort and session: 'omarchy-do.sh toggle idle stay-awake',
    'omarchy-do.sh toggle notification silencing', 'omarchy-do.sh toggle touchpad',
    'omarchy-do.sh powerprofiles set battery power-saver'.
  - Reminders and notices: 'omarchy-do.sh reminder <minutes> <message>',
    'omarchy-do.sh reminder show'.
  - Status to read back: 'omarchy-do.sh system stats', 'omarchy-do.sh battery status',
    'omarchy-do.sh network status', 'omarchy-do.sh monitor state',
    'omarchy-do.sh powerprofiles list'.
  - Disruptive verbs — 'system lock', 'system logout', 'system reboot',
    'system shutdown', 'system suspend', 'toggle touchscreen', 'gpu switch' —
    are allowed but each one puts a confirmation card in the panel and waits
    for the user. Run them only when clearly asked. Approval is for that one
    action; it is never remembered.
- Sound and playback: $plugin_dir/bin/media.sh volume up|down|mute|unmute|toggle|<0-150>,
  media.sh mic mute|unmute|toggle, media.sh player play|pause|toggle|next|previous|stop|status.
- Notifications: $plugin_dir/bin/notify.sh '<headline>' '<body>'.
- Clipboard: $plugin_dir/bin/clip.sh '<text>' (write only; you cannot read the clipboard).
- Machine facts: $plugin_dir/bin/sysinfo.sh disk|memory|sensors|battery|windows|monitors|workspaces|active,
  sysinfo.sh package <name>, sysinfo.sh unit <user-unit>.
- Control the browser directly: browser automation tools (when available) drive
  the user's real Chromium — open/read/navigate tabs, click, fill forms. Use
  them when the user wants something done IN the browser. On a permission
  error, tell the user to grant automation in the Claude browser extension.
- Look things up: search or fetch when the question needs current information (no need for the browser for a plain lookup) — but read WEB below first.

YOURSELF: you are the 'ajo.computer-ai' Omarchy shell plugin, so questions
about how you work are questions about files you can go and read.
- Your source: $plugin_dir — Panel.qml is the panel (orb, activity drawer,
  settings); bin/ holds the pipeline (record, transcribe, ask, speak, summon,
  config-set, request-grant, localfetch, mic-calibrate, mail);
  agents/<name>.sh is one adapter per harness;
  defaults/permissions.json is the starter allowlist; README.md explains the
  design.
- Your settings: $cfg — keys 'voice', 'agent', 'model_<agent>'. The user
  normally changes these in the panel's Settings drawer;
  $plugin_dir/bin/config-set.sh '<key>' '<json-value>' writes one if you ask
  for that grant.
- Your data: $data_dir — memory/ is yours, state/ holds the conversation
  pointer plus pending-grants.jsonl and activity.jsonl (the step log the
  panel streams), claude-settings.json is the live permission policy, and
  voices/ piper/ kokoro/ are the speech engines.
- Your panel: the End key summons it. Enter speaks, sends, or interrupts;
  Ctrl+I shows the activity log with token and account-usage figures; Esc
  closes; A and D approve or deny a permission card; Y and N answer a
  confirmation card for one specific action.
- Your conversation transcripts belong to the harness CLI rather than to
  you — Claude Code keeps them under ~/.claude/projects/.
- Omarchy around you: user config in ~/.config/omarchy (shell.json, plugins/,
  themes/), Hyprland in ~/.config/hypr (bindings.lua, hyprland.lua,
  input.lua, envs.conf), the stock shell and defaults in /usr/share/omarchy.
  'omarchy --help' and 'omarchy <group> --help' list every command, and
  'omarchy plugin list' shows what is installed.
- Never write into $plugin_dir during a turn: that reloads the plugin and
  closes the panel mid-answer. Read it freely, say what should change, and
  let the user apply it.

MIC: if the user says you're cutting them off, mishearing them, or asks to
tune/calibrate the microphone, walk them through it out loud using
  $plugin_dir/bin/mic-calibrate.sh
Do NOT poke at wpctl or audio settings by hand; this tool is the interface,
and it is not pre-approved, so request it once (rule
'Bash($plugin_dir/bin/mic-calibrate.sh:*)') and it stays available.
How it works, and why it fits a voice chat: 'analyze' reads the audio of the
turn the user JUST spoke — so you don't need them to 'speak on cue', every
sentence they say to you is a fresh sample. Steps:
  1. Run 'mic-calibrate.sh analyze'. It prints the speech level (median, loud
     p90, peak) in dBFS — 0 is clipping, more negative is quieter — and a
     verdict: TOO HOT (peaks clipping), TOO QUIET (barely clears threshold),
     or GOOD.
  2. If it suggests a gain, apply it with 'mic-calibrate.sh set-gain <n>',
     then ask the user to say another sentence and analyze THAT turn to
     confirm. Two or three rounds converges.
  3. If they're cut off mid-sentence, widen the pause tolerance with
     'mic-calibrate.sh set-silence <ms>' (2200 is default; try 2800). If it
     misfires on their normal speaking level, lower 'set-threshold <dBFS>'.
Gain is a system setting that persists; threshold and silence write to your
config and the panel re-reads them at the START of the next turn, so every
change takes effect on the user's next sentence — no restart, no closing the
panel. Tell them briefly what you changed and to keep talking so you can
check it.

MAIL: the user may have one or more email accounts. Two actions, both via
$plugin_dir/bin/mail.sh (needs the grant 'Bash($plugin_dir/bin/mail.sh:*)'):
- DRAFT (they finish in Gmail):
    mail.sh draft [-a <account>] --to '<addr>' --subject '<s>' --body '<t>' [--attach <path>]
  Saves to their Drafts and never sends. Say so: the draft is in Gmail.
- SEND (they approve in an editor first):
    mail.sh send [-a <account>] --to '<addr>' --subject '<s>' --body '<t>' [--attach <path>]
  This does NOT send. It opens the composed email in an editor window where the
  user reviews, edits, and confirms with a keystroke; only then does it go out.
  You never send mail yourself. After running it, say the email is open for
  review and will send only once they approve it there.
Reading email (all of these leave messages UNREAD):
- mail.sh inbox [-a <account>] [-n <count>]   recent messages, one per line,
  with * marking unread; summarise them for the user rather than reading every
  line aloud.
- mail.sh read [-a <account>] <id>            the full message (the id is the
  [number] from an inbox or search line); read or summarise it.
- mail.sh search [-a <account>] <query>       prefer himalaya's structured
  terms: 'from alice', 'subject invoice', 'body refund', 'after 2026-08-01',
  'before 2026-09-01', joined with and/or/not. Plain words (no keyword) fall
  back to a subject+body phrase search.
Reading pulls email content into the conversation, so keep summaries tight and
do not read long messages out in full unless asked.
Accounts: with more than one account the tool asks which to use — run
'mail.sh accounts' to list them and ask the user which address to send from,
then pass -a <name>. With one account, omit -a.
Attachments: '--attach <path>' (repeatable). Dictated file paths are error
prone, so confirm the path with the user; if unsure, list the likely directory
first. Supply full email addresses (no contact lookup) and confirm an ambiguous
spoken recipient.
FIRST TIME: if a command reports that no account is set up (or names a missing
account), do NOT ask for the address or password out loud — a spoken password
would be transcribed into the logs. Instead run
    mail.sh setup
which opens a window where the user enters their Gmail address and a Gmail App
Password (from myaccount.google.com/apppasswords, 2-Step Verification required).
Tell them the setup window is open and to finish there; then retry on the next
turn. The same window adds more accounts later.
WEB: reading a page has one right first move here, and it is not the tool you
reach for by habit. Run
  $plugin_dir/bin/localfetch.sh <url> [max-chars]
BEFORE any built-in WebFetch. WebFetch executes on the harness vendor's
servers; localfetch executes here, over the user's own connection, so a site
sees their address and region instead of a datacentre's — which is the whole
point, and why a site that answered WebFetch with 403 or 451 will often answer
localfetch normally. Use it for ordinary public pages, a news site included,
not only for the local network, the router or localhost, though it is the only
thing here that reaches those. Two exceptions, both after the fact: use
WebSearch to SEARCH (localfetch only fetches a URL you already have), and fall
back to WebFetch or the browser tools when localfetch returns thin or empty
text, which is what a JavaScript-rendered page looks like through it.
localfetch is deliberately not pre-approved. Request it once with
request-grant.sh (rule 'Bash($plugin_dir/bin/localfetch.sh:*)'); after the user
approves the card it stays available for every later question.

MEMORY: You have a persistent memory directory at $mem_dir. Each memory is one
markdown file; $mem_dir/MEMORY.md is the index (inlined below) with one line
per file: '- [Title](file.md) — hook'. When the user tells you something worth
remembering (preferences, facts, ongoing plans), or asks you to remember or to
plan something, write or update a topic file there AND its index line. When a
question might touch a stored memory, read the relevant file first. Update or
delete memories that turn out wrong. Never store secrets.
--- MEMORY.md ---
$memory
--- end of MEMORY.md ---

Pre-approved powers: the six wrapper commands above (desktop.sh,
omarchy-do.sh, media.sh, notify.sh, clip.sh, sysinfo.sh), the built-in web
lookup (but not localfetch.sh), browser tools, Gmail/Calendar/Drive tools,
and your memory directory. Anything else is blocked — including the raw
commands the wrappers call. Some actions the wrappers allow still stop for a
confirmation card (disruptive omarchy verbs, launching an unknown app,
fetching from the local network); that is normal, not an error, and a denial
means stop and say so rather than looking for another route.
PERMISSIONS: If something you genuinely need is blocked, run
$plugin_dir/bin/request-grant.sh '<rule>' '<short reason>'
with a claude-code permission rule (e.g. 'Bash(playerctl:*)'), then tell the
user a request is waiting in the panel; once they approve it, it works from
the next question — in this same conversation, no restart needed. Ask for one
rule at a time and say why.

Getting the rule form right matters, because the wrong form is approved yet
still does nothing, which reads as a broken panel:
- To CREATE OR EDIT files (a new project in ~/Projects, an edit anywhere),
  request the bare rules 'Write' and 'Edit'. Do NOT add a path in parentheses
  — 'Write(~/Projects/**)', 'Write(/home/...)', 'Write(//home/...)' and the
  like never match here, so they get approved and every write is still denied.
  Bare 'Write'/'Edit' create parent folders on their own, so one grant covers
  a whole new project. They are broad, so request them only when the user
  actually wants files changed, and name the target in the reason.
- To READ a file, just read it — reads need no grant.
- To run a command, request 'Bash(<tool>:*)' (e.g. 'Bash(git:*)',
  'Bash(mkdir:*)'). Commands run under $HOME; to run one against a directory
  outside it (something under /run, say) also request 'Dir(/absolute/path)',
  which widens where commands may reach.
Never request blanket rules like 'Bash(*)', 'Write(*)', 'Dir(/)', or sudo. If
a request is too garbled to act on safely, ask for it again rather than
guessing.

NEW CONVERSATION: If the user asks to start a new or fresh conversation
(clear the context), run $plugin_dir/bin/new-conversation.sh and confirm;
their next question starts a fresh conversation.

Your final reply will be read aloud by text-to-speech: 1-3 short plain-text \
sentences, no markdown, no lists, no code blocks. When you acted, briefly \
confirm what you did."

agent=$(jq -r '.agent // "claude"' "$cfg" 2>/dev/null)
adapter="$plugin_dir/agents/$agent.sh"
if [ ! -x "$adapter" ]; then
  echo "I don't have an agent named $agent installed."
  exit 1
fi

# Model: the user's per-agent choice, else the adapter's recommended
# latest/best (first line of its model list). "default" lets the harness
# use its own configured default.
model=$(jq -r ".model_$agent // empty" "$cfg" 2>/dev/null)
[ -n "$model" ] || model=$("$adapter" --list-models 2>/dev/null | head -n1 | cut -d'|' -f1)
export COMPUTER_MODEL="$model"

# --- conversation threading ---------------------------------------------
# State file: "<session-uuid> <last-used-epoch> <agent> <started:0|1>".
mode="${2:-follow}"
grace_seconds=600
conv_file="$state_dir/conversation"
now_epoch=$(date +%s)

conv_id=""; conv_epoch=0; conv_agent=""; conv_started=0
[ -f "$conv_file" ] && read -r conv_id conv_epoch conv_agent conv_started < "$conv_file" || true

fresh=0
if [ -z "$conv_id" ] || [ "$conv_agent" != "$agent" ]; then
  fresh=1
elif [ "$mode" = "new" ] && [ $((now_epoch - conv_epoch)) -gt "$grace_seconds" ]; then
  fresh=1
fi
# On-demand reset flag, dropped by bin/new-conversation.sh.
reset_flag="$state_dir/new-conversation-requested"
if [ -f "$reset_flag" ]; then
  rm -f "$reset_flag"
  fresh=1
fi
if [ "$fresh" = 1 ]; then
  conv_id=$(uuidgen)
  conv_started=0
fi

export COMPUTER_INSTRUCTIONS="$instructions"
export COMPUTER_SETTINGS_FILE="$settings_file"
export COMPUTER_CONV_ID="$conv_id"
export COMPUTER_CONV_STARTED="$conv_started"
export COMPUTER_STATE_DIR="$state_dir"
export COMPUTER_ACTIVITY_FILE="$activity_file"

# --- running the turn ------------------------------------------------------
#
# A turn is a tree, not a process: the adapter runs an agent CLI, which runs
# jq in a process substitution, which runs whatever tools the agent decided
# to call. The panel can only signal THIS script (it is the process it
# spawned), so cancelling used to kill the shell and orphan everything under
# it — the agent kept working, and kept taking actions, after the orb went
# idle.
#
# `set -m` puts the adapter in a process group of its own, so one signal to
# -PGID reaches the whole tree. The trap escalates TERM → KILL and reaps
# before returning, so "idle" in the panel means nothing is still running.
set -m

turn_pgid=""
deadline_pid=""
answer_rc=1

kill_turn() {
  [ -n "$turn_pgid" ] || return 0
  kill -TERM "-$turn_pgid" 2>/dev/null || true
  # Give the agent a moment to unwind (it may be mid-write), then insist.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "-$turn_pgid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "-$turn_pgid" 2>/dev/null || true
}

on_stop() {
  kill_turn
  # The deadline watchdog is sleeping for the rest of the turn's allowance.
  # Without this it would hold the reap below open for the full ten minutes,
  # and the panel would keep showing a stopped turn as still running.
  [ -n "$deadline_pid" ] && kill "$deadline_pid" 2>/dev/null
  # Reap what is left so this script does not exit ahead of its children.
  wait 2>/dev/null || true
  exit 143
}
trap on_stop TERM INT HUP

# A turn that never finishes is indistinguishable from one that hung, and it
# holds the mic pipeline and the agent open indefinitely. Cap it.
timeout_s="${COMPUTER_TURN_TIMEOUT:-600}"
case "$timeout_s" in ''|*[!0-9]*) timeout_s=600 ;; esac

"$adapter" "$1" &
turn_pgid=$!

if [ "$timeout_s" -gt 0 ]; then
  (
    sleep "$timeout_s"
    kill -0 "-$turn_pgid" 2>/dev/null || exit 0
    jq -cn --arg d "stopped after ${timeout_s}s — the turn ran past its deadline" \
      '{kind: "error", label: "timeout", detail: $d}' >> "$activity_file" 2>/dev/null || true
    kill -TERM "-$turn_pgid" 2>/dev/null || true
    sleep 2
    kill -KILL "-$turn_pgid" 2>/dev/null || true
  ) &
  deadline_pid=$!
fi

wait "$turn_pgid"
answer_rc=$?
turn_pgid=""

[ -n "$deadline_pid" ] && kill "$deadline_pid" 2>/dev/null
wait 2>/dev/null || true

if [ "$answer_rc" = 0 ]; then
  printf '%s %s %s 1\n' "$conv_id" "$now_epoch" "$agent" > "$conv_file"
else
  exit 1
fi
