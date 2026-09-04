#!/usr/bin/env bash
# Read-only machine facts, one verb at a time.
#
# Replaces `Bash(df:*)`, `Bash(free:*)`, `Bash(sensors:*)`, `Bash(pacman -Q:*)`,
# `Bash(systemctl --user status:*)` and `Bash(hyprctl:*)`. None of those is
# dangerous for its readings — the problem is the flags: `df --output=…`
# against any path, `systemctl status` on any unit, and above all hyprctl,
# whose `dispatch exec` runs anything at all. This exposes the readings and
# nothing else.
#
#   sysinfo.sh disk|memory|sensors|battery|windows|monitors|workspaces|active
#   sysinfo.sh package <name>
#   sysinfo.sh unit <user-unit>
set -u

usage() {
  cat >&2 <<'USAGE'
usage: sysinfo.sh disk|memory|sensors|battery|windows|monitors|workspaces|active
       sysinfo.sh package <name>      (is it installed, which version)
       sysinfo.sh unit <user-unit>    (systemctl --user status, no follow)
USAGE
}

have() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  disk)    have df || exit 127; exec df -h --output=source,size,used,avail,pcent,target ;;
  memory)  have free || exit 127; exec free -h ;;
  sensors) have sensors || exit 127; exec sensors ;;
  battery) have upower || exit 127; exec upower -i /org/freedesktop/UPower/devices/DisplayDevice ;;

  windows|monitors|workspaces|active)
    have hyprctl || exit 127
    case "$1" in
      windows)    exec hyprctl -j clients ;;
      monitors)   exec hyprctl -j monitors ;;
      workspaces) exec hyprctl -j workspaces ;;
      active)     exec hyprctl -j activewindow ;;
    esac
    ;;

  package)
    have pacman || exit 127
    name="${2:-}"
    # A leading dash passes any charset check and is still an option to the
    # program that receives it: `-Qo…` would inject flags into pacman, which
    # is precisely what this wrapper exists to prevent. Rejected here, and
    # `--` ends option parsing even if something slips past.
    case "$name" in
      ''|-*|*[!a-zA-Z0-9._+-]*) echo "sysinfo: bad package name" >&2; exit 2 ;;
    esac
    [ "${#name}" -le 64 ] || { echo "sysinfo: package name too long" >&2; exit 2; }
    exec pacman -Q -- "$name"
    ;;

  unit)
    unit="${2:-}"
    # Same trap as above, and worse here: `-M<host>` is systemctl's
    # --machine, so a leading dash would point this at another container's
    # manager instead of the user's own units.
    case "$unit" in
      ''|-*|*[!a-zA-Z0-9._@-]*) echo "sysinfo: bad unit name" >&2; exit 2 ;;
    esac
    [ "${#unit}" -le 96 ] || { echo "sysinfo: unit name too long" >&2; exit 2; }
    # --no-pager and a line cap: status of a chatty unit is not a way to
    # flood the turn.
    exec systemctl --user --no-pager --lines=20 status -- "$unit"
    ;;

  *)
    usage
    exit 2
    ;;
esac
