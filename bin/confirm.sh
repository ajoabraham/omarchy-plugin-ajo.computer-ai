#!/usr/bin/env bash
# Tier-3 gate: ask the human, in the panel, before ONE specific action, and
# block until they answer. Approval is per invocation — nothing here is
# remembered, so a "yes" to rebooting now is not a standing permission to
# reboot later.
#
#   confirm.sh <label> <detail>   → exit 0 approved, non-zero denied/timeout
#
# This is the boundary the wrappers in this directory use for anything
# disruptive or irreversible. It exists because prompt instructions are not
# a control: web pages, mail and browser content all reach the agent's
# context, so "the agent was told to confirm first" has to be backed by a
# gate the agent cannot talk its way past.
#
# The request travels on the activity stream the panel already tails live,
# so it appears mid-turn with no extra watcher; the verdict comes back as a
# file this script polls for.
set -u
umask 077

state="$HOME/.local/share/computer-ai/state"
mkdir -p "$state"
chmod 700 "$state" 2>/dev/null || true

label=$(printf '%s' "${1:-action}" | tr -d '\n\r' | head -c 60)
detail=$(printf '%s' "${2:-}" | tr -d '\n\r' | head -c 200)
[ -n "$label" ] || label="action"

id="$$-$(date +%s%N)"
verdict_file="$state/confirm-$id"
pending="$state/pending-confirms.jsonl"

timeout_s="${COMPUTER_CONFIRM_TIMEOUT:-120}"
case "$timeout_s" in ''|*[!0-9]*) timeout_s=120 ;; esac

emit() { # $1 = kind, $2 = "queue" to also record it as outstanding
  local line
  line=$(jq -cn --arg k "$1" --arg id "$id" --arg l "$label" --arg d "$detail" \
    '{kind: $k, id: $id, label: $l, detail: $d}') || return 0
  [ -n "${COMPUTER_ACTIVITY_FILE:-}" ] &&
    printf '%s\n' "$line" >> "$COMPUTER_ACTIVITY_FILE" 2>/dev/null
  # The queue file holds what is OUTSTANDING — the resolution notice belongs
  # on the live stream only, or a finished question would sit there looking
  # like it still needs answering.
  [ "${2:-}" = "queue" ] && printf '%s\n' "$line" >> "$pending" 2>/dev/null
  return 0
}

drop_pending() {
  local tmp
  tmp=$(mktemp "$state/.confirms.XXXXXX") || return 0
  jq -c --arg id "$id" 'select(.id != $id)' "$pending" > "$tmp" 2>/dev/null || : > "$tmp"
  mv -f "$tmp" "$pending"
}

cleanup() { rm -f "$verdict_file"; drop_pending; }

# Cancelled mid-question: the card has to come down, or it sits on the panel
# waiting for an answer that nothing is listening for any more.
on_stop() {
  cleanup
  detail="cancelled"
  emit confirm-done
  exit 143
}
trap on_stop TERM INT HUP

emit confirm queue

# The card is only useful if it is on screen. Opening is idempotent, and the
# service routes it to whichever monitor has focus.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q ajo.computer-ai open >/dev/null 2>&1 || true
elif [ -x "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell" ]; then
  "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell" -q ajo.computer-ai open >/dev/null 2>&1 || true
fi

verdict=""
deadline=$(( $(date +%s) + timeout_s ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$verdict_file" ]; then
    verdict=$(head -c 8 "$verdict_file" 2>/dev/null | tr -dc 'a-z')
    # Only a complete answer ends the wait. Anything else means we caught a
    # write in progress, so keep polling rather than reporting a refusal the
    # user never gave.
    case "$verdict" in
      allow|deny) break ;;
      *) verdict="" ;;
    esac
  fi
  sleep 0.25
done

cleanup
case "$verdict" in
  allow) detail="allowed" ;;
  deny)  detail="declined" ;;
  *)     detail="no answer in ${timeout_s}s" ;;
esac
emit confirm-done

case "$verdict" in
  allow)
    echo "The user approved: $label."
    exit 0
    ;;
  deny)
    echo "The user declined: $label. Do not retry it; say so and move on."
    exit 3
    ;;
  *)
    echo "No answer within ${timeout_s}s — treating '$label' as declined. Tell the user it is still waiting on them."
    exit 4
    ;;
esac
