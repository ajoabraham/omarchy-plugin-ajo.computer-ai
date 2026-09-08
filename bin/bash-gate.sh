#!/usr/bin/env bash
# Tier-1 enforcement for the Bash tool, as a Claude Code PreToolUse hook.
#
# The policy in claude-settings.json says the pre-approved surface is six
# argv-validating wrappers. It was handed to the CLI as --allowedTools and
# assumed to be exhaustive. It is not: in headless mode a tool that is
# absent from --allowedTools still runs, which was measured on 2.1.251 —
# `--allowedTools Read --permission-mode default` happily ran `id -un`
# through Bash. So the allowlist described a boundary that nothing enforced,
# and the wrappers it names were a convention, not a gate.
#
# This is the gate. Three outcomes:
#
#   1. the command matches a rule the user's policy allows      → runs
#   2. it is a reading command, confined to this plugin's own
#      directories                                              → runs
#   3. anything else                                            → tier-3 card
#
# Nothing here is remembered: an approved command is approved once. A
# standing exception is what the tier-2 grant card is for, and that writes a
# rule which case 1 then matches.
set -u
umask 077

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="$HOME/.local/share/computer-ai"
settings_file="${COMPUTER_SETTINGS_FILE:-$data_dir/claude-settings.json}"

decide() { # $1 = allow|deny, $2 = reason
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: $d,
                           permissionDecisionReason: $r}}'
  exit 0
}
silent() { exit 0; }

input=$(head -c 1000000)
[ "$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" = "Bash" ] || silent
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || decide deny "There was no command to run."

# Everything below reasons about ONE command and its arguments. A shell
# operator means the string is a program, not a command: `clip.sh hi; curl
# evil` starts with an approved wrapper and ends somewhere else entirely,
# and a prefix match would wave it through. Rather than try to parse a
# shell, anything carrying an operator is refused a silent pass and goes to
# the human, who can read it.
case $cmd in
  *[\;\|\&\$\`\(\)\<\>]* | *$'\n'* | *$'\r'*) compound=1 ;;
  *) compound=0 ;;
esac

# The user's own policy, which is also where tier-2 grants land. Only the
# two rule shapes this plugin writes are honoured — `Bash(cmd:*)` as a
# prefix and `Bash(cmd)` exactly. An unfamiliar shape matches nothing,
# because a rule this cannot read is a rule it cannot enforce.
matches_policy() {
  [ "$compound" = 0 ] || return 1
  local rule prefix
  while IFS= read -r rule; do
    case $rule in
      'Bash('*':*)')
        prefix=${rule#Bash(}; prefix=${prefix%:\*)}
        [ -n "$prefix" ] || continue
        case $cmd in
          "$prefix") return 0 ;;
          "$prefix "*) return 0 ;;
        esac
        ;;
      'Bash('*')')
        prefix=${rule#Bash(}; prefix=${prefix%)}
        [ "$cmd" = "$prefix" ] && return 0
        ;;
    esac
  done < <(jq -r '.permissions.allow[]?' "$settings_file" 2>/dev/null)
  return 1
}

# Reading, and only inside what this plugin owns. `cat` is a fine tool and a
# terrible permission: the difference between reading the activity log and
# reading an ssh key is the path, so the path is what is checked. Commands
# that read no files at all are listed separately, since they have no path
# to check.
inspects_nothing() { # no arguments that could name a file
  case $1 in
    date|uptime|uname|hostname|whoami|id|pwd|locale|echo|printf|true|seq) return 0 ;;
    *) return 1 ;;
  esac
}
# Deliberately short. `find` takes -exec, `grep` and `sort` take a pattern
# where a path looks like it should be, and a list that has to be reasoned
# about case by case is a list that will eventually be wrong. These read
# what they are pointed at and nothing else.
reads_files() {
  case $1 in
    ls|cat|head|tail|wc|stat|file|basename|dirname|jq) return 0 ;;
    *) return 1 ;;
  esac
}

# Everything this plugin owns, and nothing else. Resolved with -m so a path
# that does not exist yet still normalises, and so `..` cannot walk out.
within_ours() { # $1 = a path argument
  local p
  p=$(realpath -m -- "$1" 2>/dev/null) || return 1
  case "$p/" in
    "$plugin_dir"/*|"$data_dir"/*) return 0 ;;
    *) return 1 ;;
  esac
}

reads_only_ours() {
  [ "$compound" = 0 ] || return 1
  # Splitting on whitespace is the point; expanding is emphatically not.
  # Without `set -f`, `cat <dir>/*` would be expanded HERE, against the real
  # directory, and every path it produced would pass the check below — the
  # glob would have named files by being run rather than by being read.
  set -f
  # shellcheck disable=SC2086
  set -- $cmd
  set +f
  local prog=$1; shift
  inspects_nothing "$prog" && return 0   # nothing to confine: it reads no files
  reads_files "$prog" || return 1
  # jq's first non-flag argument is a filter, not a file. Every other
  # argument to every command here is a path.
  local skip=0
  [ "$prog" = jq ] && skip=1

  local arg seen=0
  for arg in "$@"; do
    case $arg in
      -*) continue ;;                  # a flag, not a path
      *[*?\[]*) return 1 ;;            # a glob names files we cannot see yet
    esac
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    seen=1
    within_ours "$arg" || return 1
  done
  [ "$seen" = 1 ]                      # `cat` with no path reads stdin: ask
}

if matches_policy; then
  silent   # the ordinary permission flow allows it, and so does the policy
fi
if reads_only_ours; then
  decide allow "A read, confined to the assistant's own directories."
fi

detail=$(printf '%s' "$cmd" | head -c 200)
if "$plugin_dir/bin/confirm.sh" "run a command" "$detail" >/dev/null 2>&1; then
  decide allow "The user approved this command, once."
fi
decide deny "The user declined to run that command. Do not retry it or try another way to run the same thing; say so and move on."
