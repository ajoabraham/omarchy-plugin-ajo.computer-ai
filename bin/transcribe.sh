#!/usr/bin/env bash
# Transcribe a recording with Voxtype. The input is raw s16le 16kHz mono PCM
# from record.sh; voxtype wants WAV, so wrap it first.
# Model: `stt_model` in ~/.config/omarchy/computer.json, defaulting to
# tiny.en (~2x faster than base.en on CPU with near-identical accuracy for
# short commands). If the fast model hears nothing, retry once with base.en.
# Tip: after `sudo voxtype setup gpu --enable` (Vulkan), base.en becomes
# fast too — set stt_model to base.en then.
# Voxtype mixes progress noise into stdout; the transcript is the last
# non-empty line once ANSI codes are stripped.
set -u
umask 077
cfg="$HOME/.config/omarchy/computer.json"
model=$(jq -r '.stt_model // "tiny.en"' "$cfg" 2>/dev/null)

raw="${1:-}"
[ -n "$raw" ] || { echo "usage: transcribe.sh <raw-pcm-file>" >&2; exit 2; }

# The panel names each capture unpredictably, which is what keeps a shared
# directory from being a problem while it is being written. Afterwards
# exactly one capture is kept, under a fixed name beside it, because
# mic-calibrate.sh measures the turn the user just spoke — so this is a
# rename, not a copy, and never a second file left lying around.
keep="$(dirname "$raw")/computer-ai-last.raw"

wav=$(mktemp --suffix=.wav)
# The converted wav is scratch and goes unconditionally; the capture is
# retired to $keep on the way out, replacing the previous turn's.
cleanup() {
  rm -f "$wav"
  if [ -f "$raw" ]; then
    # Belt and braces: record.sh creates this under umask 077, but the file
    # that survives a turn is microphone audio and gets an explicit mode.
    chmod 600 "$raw" 2>/dev/null || true
    mv -f "$raw" "$keep" 2>/dev/null || true
  fi
}
trap cleanup EXIT
ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i "$raw" -y "$wav" </dev/null || exit 1

run_stt() {
  local out
  out=$(voxtype --model "$1" transcribe "$wav" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*m//g')

  # voxtype's own summary line is authoritative — it carries the transcript in
  # quotes, and an empty pair of quotes means it heard nothing. Read it
  # directly, because the fallback below cannot tell silence from success:
  # with nothing transcribed, the last non-empty line IS the log record, and
  # the panel would hand the agent a timestamp and the word INFO as if the
  # user had said it. (Which it did: an unanswered "say something" turn came
  # back as `2026-09-04T23:31:49Z INFO Transcription completed in 0.40s: ""`.)
  local summary
  summary=$(printf '%s\n' "$out" | grep -a 'Transcription completed in' | tail -1)
  if [ -n "$summary" ]; then
    printf '%s' "$summary" | sed -n 's/.*Transcription completed in [^:]*: "\(.*\)"[[:space:]]*$/\1/p'
    return
  fi

  # No summary line (a different voxtype build): last non-empty line that is
  # neither progress noise nor a timestamped log record.
  printf '%s\n' "$out" \
    | grep -vE '^(Loading audio file|Audio format|Processing |whisper_|ggml_|[0-9]{4}-[0-9]{2}-[0-9]{2}T)' \
    | awk 'NF { last = $0 } END { if (last) print last }'
}

# Whisper does not return nothing for silence; it returns its favourite
# hallucinations. Treating these as speech costs a whole agent turn spent
# answering a word the user never said — and, now that a card can be
# answered out loud, it is noise arriving exactly when the panel is waiting
# for a yes or a no.
is_silence_artifact() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '.,!?[]() ')" in
    ''|you|thankyou|thanksforwatching|blank_audio|silence|bye) return 0 ;;
    *) return 1 ;;
  esac
}

text=$(run_stt "$model")
if is_silence_artifact "$text" && [ "$model" != "base.en" ]; then
  text=$(run_stt "base.en")
fi
is_silence_artifact "$text" && text=""
[ -n "$text" ] && printf '%s\n' "$text"
