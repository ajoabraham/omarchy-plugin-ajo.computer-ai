#!/usr/bin/env bash
# Tier-1 enforcement for the Bash tool, as a Claude Code PreToolUse hook.
#
# The policy in claude-settings.json says the pre-approved surface is six
# argv-validating wrappers. It was handed to the CLI as --allowedTools and
# assumed to be exhaustive. For the Bash tool it is not: measured on 2.1.251,
# `--allowedTools Read --permission-mode default` still ran `id -un` through
# Bash, because a command the CLI judges read-only is auto-approved. (Other
# tools do honour the list — an omitted Write is denied — so the hole is
# specific to Bash, which is the one that matters here: every wrapper in the
# policy is a Bash command.) So for the tool the whole tier-1 surface is made
# of, the allowlist described a boundary that nothing enforced.
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

. "$plugin_dir/bin/gate-lib.sh" 2>/dev/null || exit 2

read_call
case $tool in
  Bash) ;;
  ""|"!") unreadable ;;
  *) silent ;;   # some other tool, and not this hook's business
esac

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$cmd" ] || decide deny "There was no command to run."

# Matches $cmd against one of the policy's rule lists. Only the two shapes
# this plugin writes are honoured — `Bash(cmd:*)` as a prefix and `Bash(cmd)`
# exactly. An unfamiliar shape matches nothing, because a rule this cannot
# read is a rule it cannot enforce; bin/request-grant.sh refuses to queue one.
matches_rules() { # $1 = jq path to the list
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
  done < <(jq -r "$1" "$settings_file" 2>/dev/null)
  return 1
}

# Reading, and only inside what this plugin owns. `cat` is a fine tool and a
# terrible permission: the difference between reading the activity log and
# reading an ssh key is the path, so the path is what is checked. Commands
# that read no files at all are listed separately, since they have no path
# to check.
# "Reads no files" is a claim about a command AND its arguments, never about
# a name on its own: `date -f /home/you/.ssh/id_rsa` reads the key and echoes
# every line it cannot parse back as an error message. So each of these says
# which arguments keep it true.
inspects_nothing() { # $1 = program, $@ = its arguments
  local prog=$1; shift
  local a
  case $prog in
    echo|printf|seq|true)
      return 0 ;;                      # cannot open a file whatever it is handed
    date)
      for a in "$@"; do
        case $a in
          +*|-u|--utc|--universal) ;;   # a format, or the timezone switch
          *) return 1 ;;                # -f, -d, -r and anything unfamiliar
        esac
      done
      return 0 ;;
    uptime|uname|hostname|whoami|id|pwd|locale)
      for a in "$@"; do
        case $a in
          -[A-Za-z][A-Za-z]*|-[A-Za-z]) ;;   # short flags, which take no value here
          *) return 1 ;;
        esac
      done
      return 0 ;;
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
  # Both sides of the comparison have to be resolved the same way. The usual
  # install is a symlink — ~/.config/omarchy/plugins/<id> pointing at a
  # checkout — and `pwd` keeps that logical path while `realpath` does not, so
  # comparing them unresolved made the assistant raise a card to read its own
  # source, which the instructions tell it to go and do. Resolved here rather
  # than at startup because the two hot paths — a wrapper, or auto mode —
  # never reach this function.
  if [ -z "${plugin_real:-}" ]; then
    plugin_real=$(realpath -m -- "$plugin_dir" 2>/dev/null || printf '%s' "$plugin_dir")
    data_real=$(realpath -m -- "$data_dir" 2>/dev/null || printf '%s' "$data_dir")
  fi
  local p
  p=$(realpath -m -- "$1" 2>/dev/null) || return 1
  case "$p/" in
    "$plugin_real"/*|"$data_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

reads_only_ours() {
  # Splitting on whitespace is the point; expanding is emphatically not.
  # Without `set -f`, `cat <dir>/*` would be expanded HERE, against the real
  # directory, and every path it produced would pass the check below — the
  # glob would have named files by being run rather than by being read.
  set -f
  # shellcheck disable=SC2086
  set -- $cmd
  set +f
  local prog=$1; shift
  inspects_nothing "$prog" "$@" && return 0   # nothing to confine: it reads no files
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

# Auto mode: the user has said yes to all of this, until they say otherwise.
# Read from the config every time rather than cached anywhere, so turning it
# off in Settings takes effect on the very next command.
auto_mode_on() { [ "$("$plugin_dir/bin/auto-mode.sh" get 2>/dev/null)" = "on" ]; }

# Everything below reasons about ONE command and its arguments. A shell
# operator means the string is a program, not a command: `clip.sh hi; curl
# evil` starts with an approved wrapper and ends somewhere else entirely,
# and a prefix match would wave it through. Rather than try to parse a
# shell, anything carrying an operator is refused a silent pass and goes to
# the human, who can read it.
case $cmd in
  *[\;\|\&\$\`\(\)\<\>]* | *$'\n'* | *$'\r'*)
    # A program, not a command: no rule may match it. Auto mode still does,
    # because auto mode is exactly "stop asking me about commands".
    auto_mode_on && decide allow "Auto mode is on — the user approved every command until they turn it off in Settings."
    ;;
  *)
    # "Never this" outranks "yes to everything": a deny rule is the one thing
    # auto mode does not override. What neither can see is a denied command
    # hidden inside a compound string — but a compound string never reaches
    # auto mode either, it goes to the card.
    matches_rules '.permissions.deny[]?' &&
      decide deny "Your permission policy denies that command. Do not look for another way to run it."
    auto_mode_on && decide allow "Auto mode is on — the user approved every command until they turn it off in Settings."
    matches_rules '.permissions.allow[]?' && silent
    reads_only_ours && decide allow "A read, confined to the assistant's own directories."
    ;;
esac

# The user's own policy, which is also where tier-2 grants land. Only the
# two rule shapes this plugin writes are honoured — `Bash(cmd:*)` as a
# prefix and `Bash(cmd)` exactly. An unfamiliar shape matches nothing,
# because a rule this cannot read is a rule it cannot enforce.
detail=$(printf '%s' "$cmd" | head -c 200)
clamp_confirm_timeout
if "$plugin_dir/bin/confirm.sh" "run a command" "$detail" always:shell >/dev/null 2>&1; then
  decide allow "The user approved this command, once."
fi
decide deny "The user declined to run that command. Do not retry it or try another way to run the same thing; say so and move on."
