#!/usr/bin/env bash
# Speak $1 aloud, sentence-streamed: the reply is split into sentence chunks,
# each synthesized while the previous one plays, so speech starts after the
# first sentence renders instead of the whole reply. Kokoro synthesis goes
# through the persistent daemon (model stays loaded; spawned on demand);
# Piper is the fallback engine.
#
# Panel protocol per chunk, on stdout: "CHUNK", then one "LEVEL <dB>" line
# per 50ms of that chunk's audio (drives the orb + teleprompter), then
# "PLAY" as the chunk's playback-start marker.
#
# Long-running children are reaped with `wait` and killed by the TERM trap,
# so Esc/Enter silences the voice mid-word.
set -u
# Job control: every stage below runs as its own process group, so a stop
# takes down the whole stage — piper/ffmpeg/pw-play included — instead of
# just the shell that started it.
set -m
umask 077
dir="$HOME/.local/share/computer-ai"
cfg="$HOME/.config/omarchy/computer.json"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sock="${XDG_RUNTIME_DIR:-/tmp}/computer-ai-kokoro.sock"
py="$dir/kokoro/venv/bin/python"

tmpdir=$(mktemp -d)
child=""
bg_pid=""
lvl_pid=""
cleanup() { rm -rf "$tmpdir"; }

# Each pid here leads its own process group (set -m), so the negative form
# reaches the stage's whole tree: the ffmpeg inside emit_levels, the python
# under a kokoro request, whatever piper spawned.
end_group() {
  [ -n "$1" ] || return 0
  kill -TERM "-$1" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5; do
    kill -0 "-$1" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "-$1" 2>/dev/null || true
}

on_term() {
  end_group "$child"
  end_group "$bg_pid"
  end_group "$lvl_pid"
  wait 2>/dev/null || true
  cleanup
  exit 143
}
trap on_term TERM INT HUP
trap cleanup EXIT

run_stage() {
  "$@" &
  child=$!
  wait "$child"
  local rc=$?
  child=""
  return $rc
}

voice=$(jq -r '.voice // empty' "$cfg" 2>/dev/null)
kvoice=""
case "$voice" in kokoro:*) kvoice="${voice#kokoro:}" ;; esac

ensure_daemon() {
  "$py" "$script_dir/kokoro-client.py" --ping "$sock" 2>/dev/null && return 0
  rm -f "$sock"
  setsid "$py" "$script_dir/kokoro-daemon.py" >/dev/null 2>&1 </dev/null &
  local i
  for i in $(seq 60); do
    sleep 0.15
    "$py" "$script_dir/kokoro-client.py" --ping "$sock" 2>/dev/null && return 0
  done
  return 1
}

synth() { # $1 = text, $2 = out.wav; exits 0 with a non-empty wav on success
  if [ -n "$kvoice" ] && [ -x "$py" ] && [ -f "$dir/kokoro/kokoro-v1.0.onnx" ]; then
    if ensure_daemon && "$py" "$script_dir/kokoro-client.py" "$sock" "$kvoice" "$2" "$1" 2>/dev/null && [ -s "$2" ]; then
      return 0
    fi
  fi
  # Piper path — also the fallback if Kokoro is missing or failed.
  local pvoice="$voice"
  [ -n "$pvoice" ] && [ -f "$dir/voices/$pvoice.onnx" ] || pvoice="en_GB-northern_english_male-medium"
  printf '%s' "$1" > "$tmpdir/text.txt"
  "$dir/piper/piper" --model "$dir/voices/$pvoice.onnx" --output_file "$2" < "$tmpdir/text.txt" >/dev/null 2>&1
  [ -s "$2" ]
}

# Split into sentence chunks: the first sentence always streams alone (fast
# start); later sentences merge until >=40 chars so playback isn't choppy.
split_sentences() {
  printf '%s\n' "$1" | tr '\n' ' ' | sed 's/\([.!?]\)  */\1\n/g' | awk '
    NF && !started { print; started = 1; next }
    NF {
      buf = (buf == "" ? $0 : buf " " $0)
      if (length(buf) >= 40) { print buf; buf = "" }
    }
    END { if (buf != "") print buf }'
}

emit_levels() { # $1 = wav — CHUNK header + per-50ms RMS lines
  echo "CHUNK"
  ffmpeg -hide_banner -nostats -loglevel error -i "$1" \
    -af "aresample=16000,asetnsamples=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
    -f null - </dev/null | awk -F= '/RMS_level/ { print "LEVEL " $2 }'
}

# Bound before anything is split, synthesized or spoken. The panel clamps
# too; this is the producer-side guard for any other caller (IPC `say`).
text=$(printf '%s' "${1:-}" | head -c "${COMPUTER_SPEAK_MAX_BYTES:-8000}")
[ -n "$text" ] || exit 0

mapfile -t chunks < <(split_sentences "$text")
[ "${#chunks[@]}" -gt 0 ] || exit 0

# Character-count fractions per chunk, so the panel's teleprompter can map
# chunk-local playback progress onto the whole reply ("FRAC <start> <end>").
total_chars=0
for c in "${chunks[@]}"; do total_chars=$((total_chars + ${#c})); done
cum_chars=0

# Even the first synthesis runs as an owned job: a stop during the ~1s of
# model warm-up must take piper/kokoro with it, not leave it rendering.
synth "${chunks[0]}" "$tmpdir/0.wav" &
bg_pid=$!
wait "$bg_pid" || exit 1
bg_pid=""

for ((i = 0; i < ${#chunks[@]}; i++)); do
  # Kick off the next chunk's synthesis before playing this one.
  if [ $((i + 1)) -lt "${#chunks[@]}" ]; then
    synth "${chunks[$((i + 1))]}" "$tmpdir/$((i + 1)).wav" &
    bg_pid=$!
  else
    bg_pid=""
  fi

  awk -v a="$cum_chars" -v b=$((cum_chars + ${#chunks[$i]})) -v t="$total_chars" \
    'BEGIN { printf "FRAC %.4f %.4f\n", a/t, b/t }'
  cum_chars=$((cum_chars + ${#chunks[$i]}))
  emit_levels "$tmpdir/$i.wav" &
  lvl_pid=$!
  wait "$lvl_pid" || true
  lvl_pid=""
  echo "PLAY"
  run_stage pw-play "$tmpdir/$i.wav"

  if [ -n "$bg_pid" ]; then
    wait "$bg_pid" || true
    bg_pid=""
  fi
done
