#!/usr/bin/env bash
# Record the default mic to $1 as raw s16le 16kHz mono PCM, for at most $2
# seconds, while streaming one RMS level line per 50ms of audio to stdout
# (for the panel's orb and voice-activity endpointing). Raw PCM with
# per-packet flushing stays valid no matter how the recorder is killed —
# WAV finalization proved unreliable under the shell's process teardown.
# transcribe.sh converts it back to WAV. stderr lands in the state log.
set -u
out="$1"
max="${2:-60}"
log_dir="$HOME/.local/share/computer/state"
mkdir -p "$log_dir"
exec ffmpeg -hide_banner -nostats -loglevel error -f pulse -i default \
  -af "aresample=16000,asetnsamples=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-:direct=1" \
  -t "$max" -ar 16000 -ac 1 -f s16le -flush_packets 1 -y "$out" \
  </dev/null 2>>"$log_dir/record.log"
