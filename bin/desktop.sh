#!/usr/bin/env bash
# Launching apps and opening links, with the argv checked.
#
# This replaces `Bash(uwsm-app:*)`, `Bash(xdg-open:*)` and `Bash(hyprctl:*)`
# in the default policy. Those three were each, on their own, a general
# process launcher: `uwsm-app -- <anything>`, `hyprctl dispatch exec
# <anything>`, and xdg-open against a .desktop file or a scheme handler. With
# any of them pre-approved, the permission card was decoration.
#
#   desktop.sh launch <app>        known apps run; anything else confirms
#   desktop.sh open-url <url>      http(s) only, no file:/data:/javascript:
#
# Launch goes through `omarchy launch`, which resolves a name to a desktop
# entry — the agent never composes a command line.
set -u

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Everyday, obviously-safe app names. Anything outside this list is not
# refused — a desktop assistant that cannot open your apps is useless — but
# it costs one confirmation, so an injected "open this thing" is visible.
known_apps='
terminal
browser
editor
files
nautilus
music
spotify
signal
obsidian
slack
discord
calendar
settings
activity
docker
'

usage() {
  cat >&2 <<'USAGE'
usage: desktop.sh launch <app> [url]
       desktop.sh open-url <http(s)://...>
Known apps launch immediately; any other name asks the user to confirm.
URLs must be http or https — file, data, javascript and custom schemes are
refused outright.
USAGE
}

cmd="${1:-}"
shift || true

case "$cmd" in
  launch)
    app="${1:-}"
    extra="${2:-}"
    [ -n "$app" ] || { usage; exit 2; }
    # A desktop-entry name, not a command line: no spaces, no separators, no
    # path traversal, nothing a shell would find interesting.
    case "$app" in
      *[!a-zA-Z0-9._-]*|''|.*|*..*)
        echo "desktop: '$app' is not a valid app name" >&2; exit 2 ;;
    esac
    [ "${#app}" -le 64 ] || { echo "desktop: app name too long" >&2; exit 2; }

    # The optional second argument only makes sense as a URL for the browser.
    args=("$app")
    if [ -n "$extra" ]; then
      case "$extra" in
        http://*|https://*) ;;
        *) echo "desktop: launch takes an http(s) URL as its second argument" >&2; exit 2 ;;
      esac
      [ "${#extra}" -le 2048 ] || { echo "desktop: URL too long" >&2; exit 2; }
      args+=("$extra")
    fi

    if ! printf '%s\n' "$known_apps" | grep -qxF "$app"; then
      "$self/confirm.sh" "launch $app" "The assistant wants to launch: $app" || exit 3
    fi
    exec omarchy launch "${args[@]}"
    ;;

  open-url)
    url="${1:-}"
    [ -n "$url" ] || { usage; exit 2; }
    [ "${#url}" -le 2048 ] || { echo "desktop: URL too long" >&2; exit 2; }
    case "$url" in
      http://*|https://*) ;;
      *) echo "desktop: only http:// and https:// URLs can be opened" >&2; exit 2 ;;
    esac
    # A newline would let one "URL" become two arguments in anything that
    # re-parses this line later.
    case "$url" in
      *[$'\n\r\t']*) echo "desktop: URL contains control characters" >&2; exit 2 ;;
    esac
    exec omarchy launch browser "$url"
    ;;

  *)
    usage
    exit 2
    ;;
esac
