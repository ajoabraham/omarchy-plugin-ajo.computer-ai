#!/usr/bin/env bash
# Do the spoken approval words survive this machine's speech-to-text?
#
#   bash tests/voice-phrases.sh
#
# Decisions.js is unit-tested against typed strings (tests/decisions.js), but
# the words arrive here through a microphone and whisper, not a keyboard. So
# each phrase is synthesized with the plugin's own TTS, run through the real
# transcribe.sh, and the transcript is put to the real matcher. It is the
# same journey a spoken answer makes, minus the room.
#
# Skips itself when the engines are not installed.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data="$HOME/.local/share/computer-ai"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

command -v voxtype >/dev/null 2>&1 || { echo "  --   skipped: voxtype not installed"; exit 0; }
command -v node >/dev/null 2>&1    || { echo "  --   skipped: node not installed"; exit 0; }
voice=$(ls "$data/voices"/*.onnx 2>/dev/null | head -1)
[ -n "$voice" ] && [ -x "$data/piper/piper" ] || { echo "  --   skipped: no piper voice installed"; exit 0; }

pass=0; fail=0

say_and_decide() { # $1 = phrase -> prints the matcher's verdict
  printf '%s' "$1" | "$data/piper/piper" --model "$voice" \
    --output_file "$work/say.wav" >/dev/null 2>&1
  ffmpeg -hide_banner -loglevel error -i "$work/say.wav" \
    -ar 16000 -ac 1 -f s16le -y "$work/say.raw" </dev/null || return 1
  local heard
  heard=$("$repo/bin/transcribe.sh" "$work/say.raw")
  printf '%s\t%s' "$heard" "$(node -e '
    const fs = require("fs");
    const decide = new Function(fs.readFileSync(process.argv[1], "utf8") + "; return decide;")();
    process.stdout.write(decide(process.argv[2]));
  ' "$repo/Decisions.js" "$heard")"
}

check() { # phrase, expected verdict
  local phrase="$1" want="$2" out heard got
  out=$(say_and_decide "$phrase") || { echo "  FAIL $phrase (synthesis failed)"; fail=$((fail+1)); return; }
  heard=${out%%$'\t'*}; got=${out##*$'\t'}
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok   said %-16s heard %-24s -> %s\n' "\"$phrase\"" "\"$heard\"" "${got:-(not a decision)}"
  else
    fail=$((fail+1)); printf '  FAIL said %-16s heard %-24s -> %s, wanted %s\n' "\"$phrase\"" "\"$heard\"" "${got:-none}" "$want"
  fi
}

echo "spoken approvals, through the real speech-to-text:"
check "Allow."        allow
check "Yes."          allow
check "Go ahead."     allow
check "Do it."        allow
check "Deny."         deny
check "No."           deny
check "Cancel."       deny
check "Never mind."   deny
echo "and things that only sound like an answer:"
check "What does that do?"                ""
check "Yes, but tell me more first."      ""

echo
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
