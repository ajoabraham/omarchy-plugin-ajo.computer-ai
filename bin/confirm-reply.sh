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
printf '%s' "$verdict" > "$state/confirm-$id"
