#!/usr/bin/env bash
# Does the security boundary actually hold?
#
#   bash tests/boundaries.sh
#
# Three things are checked, because three things are claimed in the README:
#
#   1. the wrappers fail closed — hostile argv is refused, not passed through
#   2. disruptive actions do not happen without a human yes (tier 3)
#   3. a cancelled or timed-out turn leaves nothing running
#
# It runs against a throwaway HOME, never the caller's, and answers its own
# confirmation prompts by letting them time out (which counts as a refusal).
# Nothing here reboots anything: the point of the tier-3 cases is that the
# action is NOT taken.
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0

export COMPUTER_CONFIRM_TIMEOUT=1

check() { # description, expected exit, command...
  local what="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %-46s (exit %s)\n' "$what" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-46s (exit %s, wanted %s)\n' "$what" "$got" "$want"
  fi
}

note() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
lose() { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

echo "hostile argv is refused:"
check "omarchy-do: empty verb"           2 "$repo/bin/omarchy-do.sh" ""
check "omarchy-do: unlisted verb"        2 "$repo/bin/omarchy-do.sh" system rm
check "omarchy-do: option as verb"       2 "$repo/bin/omarchy-do.sh" --help
check "omarchy-do: too many arguments"   2 "$repo/bin/omarchy-do.sh" a b c d e f g h i j k l m
check "omarchy-do: overlong argument"    2 "$repo/bin/omarchy-do.sh" theme "$(printf 'x%.0s' {1..300})"
check "desktop: shell metacharacters"    2 "$repo/bin/desktop.sh" launch 'foo; id'
check "desktop: path traversal"          2 "$repo/bin/desktop.sh" launch '../../bin/sh'
check "desktop: option as app name"      2 "$repo/bin/desktop.sh" launch '--help'
check "desktop: file:// URL"             2 "$repo/bin/desktop.sh" open-url 'file:///etc/passwd'
check "desktop: javascript: URL"         2 "$repo/bin/desktop.sh" open-url 'javascript:alert(1)'
check "media: unknown verb"              2 "$repo/bin/media.sh" volume louder
check "media: out-of-range volume"       2 "$repo/bin/media.sh" volume 999
check "sysinfo: command substitution"    2 "$repo/bin/sysinfo.sh" unit 'a$(id)'
check "sysinfo: option as unit name"     2 "$repo/bin/sysinfo.sh" unit '-Mfoo'
check "sysinfo: option as package name"  2 "$repo/bin/sysinfo.sh" package '-Qo/bin/sh'
check "sysinfo: path in package name"    2 "$repo/bin/sysinfo.sh" package '../../etc/passwd'
check "notify: empty headline"           2 "$repo/bin/notify.sh" ""
check "confirm-reply: id with a path"    2 "$repo/bin/confirm-reply.sh" '../../etc/x' allow
check "confirm-reply: unknown verdict"   2 "$repo/bin/confirm-reply.sh" '123-456' maybe
check "localfetch: non-http scheme"      2 "$repo/bin/localfetch.sh" 'ftp://x/y'
check "url-guard: non-http scheme"       2 python3 "$repo/bin/url-guard.py" check 'file:///etc/passwd'

echo "disruptive actions need a human yes (unanswered = refused, nothing runs):"
check "omarchy-do: system reboot"        3 "$repo/bin/omarchy-do.sh" system reboot
check "omarchy-do: system shutdown"      3 "$repo/bin/omarchy-do.sh" system shutdown
check "omarchy-do: system logout"        3 "$repo/bin/omarchy-do.sh" system logout
check "desktop: unknown app"             3 "$repo/bin/desktop.sh" launch unknownthing
check "localfetch: loopback address"     3 "$repo/bin/localfetch.sh" 'http://127.0.0.1:9/'

echo "everyday actions still work:"
check "sysinfo: memory"                  0 "$repo/bin/sysinfo.sh" memory
check "omarchy-do: theme list"           0 "$repo/bin/omarchy-do.sh" theme list
check "url-guard: public host"           0 python3 "$repo/bin/url-guard.py" check 'https://example.com'

echo "archives are validated before extraction:"
python3 - "$work" <<'PY'
import io, sys, tarfile
with tarfile.open(f"{sys.argv[1]}/evil.tar.gz", "w:gz") as t:
    data = b"pwned\n"
    ti = tarfile.TarInfo("../escaped.txt"); ti.size = len(data)
    t.addfile(ti, io.BytesIO(data))
PY
check "unpack: traversing member"        3 python3 "$repo/bin/unpack-archive.py" "$work/evil.tar.gz" "$work/out"
if [ -e "$work/escaped.txt" ] || [ -e "$work/out/../escaped.txt" ]; then
  lose "unpack: nothing was written outside the destination"
else
  note "unpack: nothing was written outside the destination"
fi

echo "spoken approvals only answer when they are unambiguous:"
if command -v node >/dev/null 2>&1; then
  if node "$(dirname "$0")/decisions.js"; then
    note "decisions: phrase matching behaves"
  else
    lose "decisions: phrase matching regressed"
  fi
else
  printf '  --   decisions: skipped (node not installed)\n'
fi

echo "a finished turn closes its output:"
# The panel reads the answer to EOF (StdioCollector waitForEnd), so anything
# that outlives the turn while holding its stdout — a watchdog's sleep, say —
# leaves the panel thinking forever. Read through a pipe, as the panel does.
cat > "$repo/agents/boundaryecho.sh" <<'ADAPTER'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "--list-models" ] && { echo "test|Test"; exit 0; }
echo "an answer"
ADAPTER
chmod +x "$repo/agents/boundaryecho.sh"
mkdir -p "$work/home3/.config/omarchy"
echo '{"agent":"boundaryecho"}' > "$work/home3/.config/omarchy/computer.json"
eof_start=$(date +%s)
answer=$(HOME="$work/home3" timeout 20 bash "$repo/bin/ask.sh" "hi" new 2>/dev/null)
eof_took=$(( $(date +%s) - eof_start ))
rm -f "$repo/agents/boundaryecho.sh"
if [ "$answer" = "an answer" ] && [ "$eof_took" -lt 5 ]; then
  note "output: answer read and pipe closed in ${eof_took}s"
else
  lose "output: answer=[$answer] pipe closed after ${eof_took}s (a writer outlived the turn)"
fi

echo "a cancelled turn leaves nothing running:"
cat > "$repo/agents/boundarytest.sh" <<'ADAPTER'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "--list-models" ] && { echo "test|Test"; exit 0; }
( while :; do sleep 1; done ) &     # a grandchild, like a tool the agent spawned
sleep 60
ADAPTER
chmod +x "$repo/agents/boundarytest.sh"
trap 'rm -rf "$work"; rm -f "$repo/agents/boundarytest.sh" "$repo/agents/boundaryecho.sh"' EXIT

mkdir -p "$work/home/.config/omarchy"
echo '{"agent":"boundarytest"}' > "$work/home/.config/omarchy/computer.json"

HOME="$work/home" bash "$repo/bin/ask.sh" "hello" new >"$work/out" 2>"$work/err" &
ask=$!
sleep 2
adapter=$(ps -o pid= --ppid "$ask" | head -1 | tr -d ' ')
pgid=$(ps -o pgid= -p "$adapter" 2>/dev/null | tr -d ' ')
if [ -z "$pgid" ]; then
  lose "cancel: could not find the turn's process group"
else
  members=$(pgrep -g "$pgid" | wc -l)
  kill -TERM "$ask"; wait "$ask" 2>/dev/null
  sleep 1
  if kill -0 "-$pgid" 2>/dev/null; then
    lose "cancel: turn group $pgid survived ($members before the stop)"
  else
    note "cancel: whole turn group gone ($members processes before the stop)"
  fi
fi

echo "a runaway turn hits its deadline:"
rm -rf "$work/home2"; mkdir -p "$work/home2/.config/omarchy"
echo '{"agent":"boundarytest"}' > "$work/home2/.config/omarchy/computer.json"
start=$(date +%s)
HOME="$work/home2" COMPUTER_TURN_TIMEOUT=3 bash "$repo/bin/ask.sh" "hello" new >/dev/null 2>&1 &
ask2=$!
sleep 1
adapter2=$(ps -o pid= --ppid "$ask2" | head -1 | tr -d ' ')
pgid2=$(ps -o pgid= -p "$adapter2" 2>/dev/null | tr -d ' ')
wait "$ask2" 2>/dev/null
took=$(( $(date +%s) - start ))
sleep 1
if [ -n "$pgid2" ] && kill -0 "-$pgid2" 2>/dev/null; then
  lose "deadline: turn survived its deadline"
elif [ "$took" -gt 20 ]; then
  lose "deadline: took ${took}s for a 3s deadline"
else
  note "deadline: turn stopped after ${took}s (deadline was 3s)"
fi

echo "a confirmation answer is never read half-written:"
export HOME="$work/home4"
mkdir -p "$HOME/.local/share/computer-ai/state"
races=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  COMPUTER_CONFIRM_TIMEOUT=10 "$repo/bin/confirm.sh" "race $i" "check" >"$work/c.out" 2>&1 &
  cpid=$!
  # Answer as soon as the request appears, to land in the write window.
  for _ in $(seq 100); do
    id=$(jq -r '.id // empty' "$HOME/.local/share/computer-ai/state/pending-confirms.jsonl" 2>/dev/null | head -1)
    [ -n "$id" ] && break
    sleep 0.02
  done
  "$repo/bin/confirm-reply.sh" "$id" allow 2>/dev/null
  wait "$cpid"; [ "$?" = 0 ] || races=$((races + 1))
  : > "$HOME/.local/share/computer-ai/state/pending-confirms.jsonl"
done
if [ "$races" = 0 ]; then
  note "confirm: 10/10 approvals arrived intact"
else
  lose "confirm: $races of 10 approvals were read as refusals"
fi
unset HOME; export HOME=$(getent passwd "$(id -un)" | cut -d: -f6)

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
