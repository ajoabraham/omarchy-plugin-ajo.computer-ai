#!/usr/bin/env bash
# Does a spoken turn reach the agent whole?
#
#   bash tests/transcript.sh
#
# voxtype prints the transcript twice: once elided into its own log summary
# line, at 50 characters plus an ellipsis, and once in full on a plain line
# of its own. transcribe.sh read the summary, so for a while every turn
# longer than a short sentence arrived cut to 53 characters — while the
# panel, the microphone and whisper were all working perfectly.
#
# The summary line still has one job, and it is the reason it was read in the
# first place: with nothing transcribed there is no plain line, and the empty
# pair of quotes is the only way to tell silence from success. So the two
# jobs are split, and both halves are pinned here.
#
# The fixtures are real voxtype 0.7.5 output, captured from this machine. No
# microphone and no model: a stub on PATH replays them, so the parsing is
# tested wherever this runs. The last section does use the real engines when
# they happen to be installed, because a fixture cannot notice voxtype
# changing its output.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

command -v ffmpeg >/dev/null 2>&1 || { echo "  --   skipped: ffmpeg not installed"; exit 0; }

# A throwaway HOME, so the caller's stt_model setting cannot change the
# answers, and a stub voxtype that replays a fixture instead of listening.
mkdir -p "$work/home/.config/omarchy" "$work/bin" "$work/cases"
echo '{"stt_model":"tiny.en"}' > "$work/home/.config/omarchy/computer.json"
cat > "$work/bin/voxtype" <<'STUB'
#!/usr/bin/env bash
cat "$VOXTYPE_FIXTURE"
STUB
chmod +x "$work/bin/voxtype"

# 5.5s of silence: the bytes are never looked at, only the pipeline is.
head -c 176000 /dev/zero > "$work/turn.raw"

heard() { # $1 = fixture file -> prints what the agent would receive
  local d; d=$(mktemp -d "$work/run.XXXXXX")
  cp "$work/turn.raw" "$d/in.raw"
  PATH="$work/bin:$PATH" HOME="$work/home" VOXTYPE_FIXTURE="$1" \
    bash "$repo/bin/transcribe.sh" "$d/in.raw"
  rm -rf "$d"
}

check() { # description, fixture, expected transcript
  local what="$1" fixture="$2" want="$3" got
  got=$(heard "$fixture")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %-44s %3d chars\n' "$what" "${#got}"
  else
    fail=$((fail + 1))
    printf '  FAIL %-44s\n         got  [%s]\n         want [%s]\n' "$what" "$got" "$want"
  fi
}

full="I want you to summarize the issue and put it on the clipboard so I can paste it into Cloud Code."

# What voxtype 0.7.5 actually prints for that turn. Note the summary line
# stopping mid-word at 50 characters, and the blank line before the real one.
cat > "$work/cases/long.txt" <<EOF
Loading audio file: "turn.wav"
Audio format: 16000 Hz, 1 channel(s), Int
Processing 88000 samples (5.50s)...
2026-09-07T14:59:20.268897Z  INFO Using local whisper transcription mode
2026-09-07T14:59:20.268909Z  INFO Loading whisper model from "/home/ajo/.local/share/voxtype/models/ggml-tiny.en.bin"
2026-09-07T14:59:20.302010Z  INFO Model loaded in 0.03s
2026-09-07T14:59:20.724901Z  INFO Transcription completed in 0.42s: "I want you to summarize the issue and put it on th..."

$full
EOF

cat > "$work/cases/short.txt" <<'EOF'
Loading audio file: "turn.wav"
Processing 16000 samples (1.00s)...
2026-09-07T14:59:20.724901Z  INFO Transcription completed in 0.30s: "Go ahead."

Go ahead.
EOF

# Silence: no plain line at all, so the last non-empty line IS the log
# record. Reading the words from there once handed the agent a timestamp and
# the word INFO as if it had been spoken.
cat > "$work/cases/silence.txt" <<'EOF'
Loading audio file: "turn.wav"
Processing 88000 samples (5.50s)...
2026-09-07T14:59:20.268897Z  INFO Using local whisper transcription mode
2026-09-07T14:59:20.724901Z  INFO Transcription completed in 0.40s: ""
EOF

# Same, with the trailing whitespace some terminals leave behind.
sed 's/: ""$/: ""   /' "$work/cases/silence.txt" > "$work/cases/silence-padded.txt"

# A build that prints no summary line.
cat > "$work/cases/no-summary.txt" <<EOF
Loading audio file: "turn.wav"
Processing 88000 samples (5.50s)...
$full
EOF

# A build that prints no plain line. Truncated is all there is, and a
# truncated transcript beats none — this is the pre-fix behaviour, kept.
cat > "$work/cases/no-plain.txt" <<'EOF'
Loading audio file: "turn.wav"
Processing 88000 samples (5.50s)...
2026-09-07T14:59:20.724901Z  INFO Transcription completed in 0.42s: "I want you to summarize the issue and put it on th..."
EOF

# Punctuation the summary line's own quoting cannot survive.
cat > "$work/cases/quoted.txt" <<'EOF'
Loading audio file: "turn.wav"
Processing 88000 samples (5.50s)...
2026-09-07T14:59:20.724901Z  INFO Transcription completed in 0.42s: "She said "no", so: stop. Then tell me what happene..."

She said "no", so: stop. Then tell me what happened.
EOF

echo "a spoken turn reaches the agent whole:"
check "long turn is not cut at 50 characters" "$work/cases/long.txt"        "$full"
check "short turn is unchanged"               "$work/cases/short.txt"       "Go ahead."
check "quotes and colons survive"             "$work/cases/quoted.txt"      'She said "no", so: stop. Then tell me what happened.'
check "no summary line: the plain line wins"  "$work/cases/no-summary.txt"  "$full"

echo "silence is still silence, not a log record:"
check "empty quotes mean nothing was said"    "$work/cases/silence.txt"         ""
check "even with trailing whitespace"         "$work/cases/silence-padded.txt"  ""

echo "a build with no plain line still works, truncation and all:"
check "summary text is the last resort"       "$work/cases/no-plain.txt" \
  "I want you to summarize the issue and put it on th..."

# The fixtures above pin the parsing; only the real thing can tell us voxtype
# still prints what they say it does. Spoken, not synthesized from a string:
# this is the same journey a real turn makes, minus the room.
echo "and through the real engines, when they are installed:"
data="$HOME/.local/share/computer-ai"
voice=$(ls "$data/voices"/*.onnx 2>/dev/null | head -1)
if ! command -v voxtype >/dev/null 2>&1; then
  printf '  --   real voxtype: skipped (not installed)\n'
elif [ -z "$voice" ] || [ ! -x "$data/piper/piper" ]; then
  printf '  --   real voxtype: skipped (no piper voice installed)\n'
else
  said="I want you to summarize the issue and put it on the clipboard."
  printf '%s' "$said" | "$data/piper/piper" --model "$voice" \
    --output_file "$work/say.wav" >/dev/null 2>&1
  if ffmpeg -hide_banner -loglevel error -i "$work/say.wav" \
       -ar 16000 -ac 1 -f s16le -y "$work/say.raw" </dev/null; then
    d=$(mktemp -d "$work/real.XXXXXX"); mv "$work/say.raw" "$d/in.raw"
    got=$("$repo/bin/transcribe.sh" "$d/in.raw")
    # Not the exact words — whisper is allowed its own spelling. The
    # invariant is that a 61-character sentence does not come back as 53
    # characters ending in an ellipsis.
    case ${#got}:$got in
      *:*...) fail=$((fail + 1)); printf '  FAIL real voxtype: elided -> [%s]\n' "$got" ;;
      *)
        if [ "${#got}" -gt 53 ]; then
          pass=$((pass + 1)); printf '  ok   %-44s %3d chars\n' "real voxtype: heard it whole" "${#got}"
        else
          fail=$((fail + 1)); printf '  FAIL real voxtype: only %d chars -> [%s]\n' "${#got}" "$got"
        fi ;;
    esac
  else
    printf '  --   real voxtype: skipped (synthesis failed)\n'
  fi
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
