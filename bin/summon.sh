#!/usr/bin/env bash
# Summon the Computer AI panel and arm the mic — but only when it's idle, so
# summoning mid-turn just brings the running agent's progress into view rather
# than starting to record over it.
#
# The assistant is a bar widget: its icon lives in the status bar and its agent
# runs for the whole shell session, so this doesn't launch anything — it just
# opens the drop-down via IPC. The popup is a keyboard-focused layer surface,
# so Enter/Esc work immediately with no window-focus dance.
set -u
exec omarchy-shell ajo.computer-ai summon '{"listen": true}'
