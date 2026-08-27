#!/usr/bin/env bash
# Speak $1 aloud with the configured voice. Voices named "kokoro:<name>" use
# the Kokoro TTS venv; anything else is a Piper voice. Before playback, print
# one "LEVEL <dB>" line per 50ms of the synthesized audio so the panel can
# animate the orb in sync, then "PLAY" as the playback-start marker.
#
# Synthesis and playback run as background children reaped with `wait`: a
# foreground child would make bash defer SIGTERM until the child exits, so
# Esc in the panel couldn't silence the voice until the sentence finished.
set -u
dir="$HOME/.local/share/computer"
cfg="$HOME/.config/omarchy/computer.json"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wav=$(mktemp --suffix=.wav)
child=""
cleanup() { rm -f "$wav"; }
on_term() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
  cleanup
  exit 143
}
trap on_term TERM INT
trap cleanup EXIT

# Run a long stage interruptibly: background it, record the pid, wait.
# Redirections attached to the call (e.g. < file) apply to the child.
run_stage() {
  "$@" &
  child=$!
  wait "$child"
  local rc=$?
  child=""
  return $rc
}

voice=$(jq -r '.voice // empty' "$cfg" 2>/dev/null)

synthesized=false
case "$voice" in
  kokoro:*)
    kvoice="${voice#kokoro:}"
    if [ -x "$dir/kokoro/venv/bin/python" ] && [ -f "$dir/kokoro/kokoro-v1.0.onnx" ]; then
      run_stage "$dir/kokoro/venv/bin/python" "$script_dir/kokoro-say.py" "$kvoice" "$wav" "$1" \
        >/dev/null 2>&1 && [ -s "$wav" ] && synthesized=true
    fi
    ;;
esac

if [ "$synthesized" = false ]; then
  # Piper path — also the fallback if Kokoro is missing or failed.
  pvoice="$voice"
  [ -n "$pvoice" ] && [ -f "$dir/voices/$pvoice.onnx" ] || pvoice="en_GB-northern_english_male-medium"
  printf '%s' "$1" > "$wav.txt"
  run_stage "$dir/piper/piper" --model "$dir/voices/$pvoice.onnx" --output_file "$wav" < "$wav.txt" >/dev/null 2>&1
  rm -f "$wav.txt"
fi

# Level extraction is near-instant on a local file; foreground is fine.
ffmpeg -hide_banner -nostats -loglevel error -i "$wav" \
  -af "aresample=16000,asetnsamples=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
  -f null - </dev/null | awk -F= '/RMS_level/ { print "LEVEL " $2 }'

echo "PLAY"
run_stage pw-play "$wav"
