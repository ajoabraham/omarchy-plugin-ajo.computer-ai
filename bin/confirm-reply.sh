#!/usr/bin/env bash
# Panel-invoked: answer the confirmation card that confirm.sh is blocking on.
# $1 = request id (as issued by confirm.sh), $2 = allow|deny.
#
# The panel is the only writer here — the agent queues the question, the
# human answers it, exactly like the grant flow.
set -eu
umask 077
id="${1:-}"
verdict="${2:-deny}"
state="$HOME/.local/share/computer-ai/state"

# The id is a filename component, so it is validated rather than trusted:
# digits, dashes, nothing that can walk out of the state directory.
case "$id" in
  ''|*[!0-9-]*) echo "confirm-reply: bad id" >&2; exit 2 ;;
esac
case "$verdict" in
  allow|deny) ;;
  *) echo "confirm-reply: verdict must be allow or deny" >&2; exit 2 ;;
esac

mkdir -p "$state"

# Written whole, then renamed into place. A plain redirect creates the file
# empty and fills it a moment later; confirm.sh polls for existence, so that
# gap is a window where a Y is read as an empty verdict and reported back to
# the agent as a refusal. A rename has no such window.
tmp=$(mktemp "$state/.confirm.XXXXXX")
printf '%s' "$verdict" > "$tmp"
mv -f "$tmp" "$state/confirm-$id"
