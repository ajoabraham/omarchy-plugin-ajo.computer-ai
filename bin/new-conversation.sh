#!/usr/bin/env bash
# Agent-callable: request a fresh conversation. Drops a flag in the STATE
# directory (never the plugin directory — writes there trigger the shell's
# plugin hot-reload and kill the open panel); ask.sh consumes it on the next
# turn and mints a new session.
set -eu
state="$HOME/.local/share/computer-ai/state"
mkdir -p "$state"
touch "$state/new-conversation-requested"
echo "New conversation queued — the next question starts fresh."
