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
plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfg="$HOME/.config/omarchy/computer.json"
mem_dir="$HOME/.local/share/computer-ai/memory"
state_dir="$HOME/.local/share/computer-ai/state"
settings_file="$HOME/.local/share/computer-ai/claude-settings.json"
export PATH="$HOME/.local/share/mise/shims:$HOME/.grok/bin:$HOME/.local/bin:$PATH"
cd "$HOME"

mkdir -p "$mem_dir" "$state_dir"
[ -f "$mem_dir/MEMORY.md" ] || printf '# Computer memory index\n' > "$mem_dir/MEMORY.md"
# First run: seed the user's permission policy from the shipped defaults
# (never overwritten afterwards — apply-grant.sh appends user-approved rules
# to the live copy, which is user data and stays out of the repo).
if [ ! -f "$settings_file" ]; then
  sed "s|__PLUGIN_DIR__|$plugin_dir|g" "$plugin_dir/defaults/permissions.json" > "$settings_file"
fi
activity_file="$state_dir/activity.jsonl"
: > "$activity_file"

memory=$(head -c 4000 "$mem_dir/MEMORY.md" 2>/dev/null)
now=$(date '+%A, %B %d %Y, %H:%M')

instructions="You are 'Computer', a voice assistant on an Omarchy Linux desktop \
(Arch + Hyprland), in the spirit of the Star Trek ship's computer. The user's \
words arrive via speech-to-text, so tolerate small transcription errors. \
The current date and time: $now.

You may OPERATE this computer with your tools when asked. Useful desktop verbs:
- Control the browser directly: browser automation tools (when available) drive
  the user's real Chromium — open/read/navigate tabs, click, fill forms. Use
  them when the user wants something done IN the browser. On a permission
  error, tell the user to grant automation in the Claude browser extension.
- Just open a page: 'omarchy launch browser [url]' or 'xdg-open <url>'
- Launch apps: 'omarchy launch <app>' (terminal, editor, nautilus, spotify, signal...), or 'uwsm-app -- <command>' for anything else
- System controls: the 'omarchy' CLI (theme set, toggle nightlight, reminder <minutes> <text>, capture screenshot, audio output volume, system lock...)
- Look things up: fetch web pages or search when the question needs current information (no need for the browser for a plain lookup).

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

Pre-approved powers: desktop-action commands (omarchy/xdg-open/uwsm-app/
hyprctl), media and audio (wpctl, playerctl), notifications (notify-send),
clipboard (wl-copy), read-only system info (pacman -Q, systemctl --user
status, df, free, sensors, upower), web lookup, browser tools, Gmail/Calendar/
Drive tools, and your memory directory. Anything else is blocked.
PERMISSIONS: If a command you genuinely need is blocked, run
$plugin_dir/bin/request-grant.sh '<rule>' '<short reason>'
with a claude-code permission rule (e.g. 'Bash(playerctl:*)' or
'Read(~/Documents/**)'), then tell the user a permission request is waiting in
the panel for their approval; once approved it works from the next question.
Request the narrowest rule that does the job. You are also confined to $HOME as
your working directory, whatever the tool allowlist says: to reach somewhere
else (a runtime or state directory under /run, say), request that path as a
'Dir(/absolute/path)' rule the same way. Never request broad rules like
'Bash(*)', 'Dir(/)', sudo, or writes outside your own directories. If a
request sounds too garbled to act on safely, ask for it again rather than
guessing.

NEW CONVERSATION: If the user asks to start a new or fresh conversation
(clear the context), run $plugin_dir/bin/new-conversation.sh and confirm;
their next question starts a fresh conversation. Never write files into the
plugin directory itself — that reloads the plugin and closes the panel.

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

if "$adapter" "$1"; then
  printf '%s %s %s 1\n' "$conv_id" "$now_epoch" "$agent" > "$conv_file"
else
  exit 1
fi
