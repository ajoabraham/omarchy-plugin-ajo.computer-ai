#!/usr/bin/env bash
# The agent's door to the `omarchy` CLI — a table, not a passthrough.
#
# `Bash(omarchy:*)` used to be pre-approved, which handed the agent every
# verb the CLI has, `omarchy system shutdown` included, on nothing stronger
# than a prompt saying "confirm first". This script is the enforcement that
# sentence implied:
#
#   tier 1  reversible, everyday verbs — run immediately
#   tier 3  disruptive or irreversible verbs — bin/confirm.sh first, every
#           single time (per invocation; approving once grants nothing)
#   else    refused, with a pointer to request-grant.sh
#
# Arguments are passed to `omarchy` as argv, never through a shell, so the
# only question this file has to answer is which verbs are allowed.
#
#   omarchy-do.sh theme set tokyo-night
#   omarchy-do.sh audio output volume +5
#   omarchy-do.sh system reboot          → card in the panel, then maybe
set -u

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Whole-argv shapes, matched as prefixes. Keep each entry as specific as the
# verb allows: "toggle nightlight" rather than "toggle".
tier1_verbs='
theme list
theme set
theme bg
font list
font set
toggle nightlight
toggle idle
toggle notification
toggle touchpad
display text
screenshot
capture screenshot
capture text
capture screenrecording
audio output
audio input
brightness display
brightness keyboard
reminder
notification send
system stats
battery status
network status
network speedtest
monitor state
powerprofiles list
powerprofiles set
plugin list
'

# Interrupts the session, destroys state, or changes hardware the user is
# looking at. Allowed, but only with a per-invocation yes.
tier3_verbs='
system lock
system logout
system reboot
system shutdown
system suspend
toggle touchscreen
gpu switch
'

usage() {
  cat >&2 <<'USAGE'
usage: omarchy-do.sh <omarchy verb...>
Pre-approved verbs: theme, font, toggle nightlight/idle/notification/touchpad,
display text size, screenshot/capture, audio, brightness, reminder,
notification send, and the read-only status verbs (system stats, battery
status, network status, monitor state, powerprofiles list, plugin list).
Disruptive verbs (system lock/logout/reboot/shutdown/suspend, toggle
touchscreen, gpu switch) ask the user to confirm in the panel first.
USAGE
}

[ "$#" -gt 0 ] || { usage; exit 2; }

# Cardinality and length bounds before anything is matched or executed.
[ "$#" -le 12 ] || { echo "omarchy-do: too many arguments" >&2; exit 2; }
for a in "$@"; do
  [ "${#a}" -le 256 ] || { echo "omarchy-do: argument too long" >&2; exit 2; }
done

first="${1:-}"; second="${2:-}"
# An empty first argument would otherwise match the blank line the tables
# begin with, and pass straight through as an allowed verb.
[ -n "$first" ] || { usage; exit 2; }
probe="$first${second:+ $second}"

# Pure bash, deliberately: passing an untrusted value to grep as its pattern
# means a value starting with "-" is parsed as an option instead — `--help`
# made grep print its usage and exit 0, which this function then read as "the
# verb is in the table". Nothing here is a subprocess or an option.
matches() { # $1 = table, $2 = probe
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$2" ] && return 0
  done <<< "$1"
  return 1
}

command -v omarchy >/dev/null 2>&1 || { echo "omarchy: command not found" >&2; exit 127; }

if matches "$tier1_verbs" "$probe" || matches "$tier1_verbs" "$first"; then
  exec omarchy "$@"
fi

if matches "$tier3_verbs" "$probe"; then
  if "$self/confirm.sh" "omarchy $probe" "The assistant wants to run: omarchy $*"; then
    exec omarchy "$@"
  fi
  exit 3
fi

cat >&2 <<EOM
omarchy-do: '$probe' is not in the pre-approved set.
If the user genuinely wants it, request the specific rule with
  $self/request-grant.sh 'Bash(omarchy $first:*)' '<why>'
and let them approve it in the panel.
EOM
exit 2
