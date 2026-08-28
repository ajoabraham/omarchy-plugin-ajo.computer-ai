#!/usr/bin/env bash
# Claude Code harness adapter. --chrome attaches the Claude-in-Chrome
# extension relay so the agent can drive the user's real browser (needs the
# one-time automation grant in the extension; works headless because the CLI
# uses OAuth login). Permission policy maps to --allowedTools, and granted
# directories outside $HOME map to --add-dir.
#
# The turn runs as a stream (--output-format stream-json) rather than a
# single blocking call, so the panel can show what the agent is doing while
# it works: each event becomes an activity line the panel tails live, and
# the final result event is the spoken answer on stdout.
set -u

# First line is the recommended latest/best (used as the default model).
if [ "${1:-}" = "--list-models" ]; then
  printf '%s\n' \
    "claude-fable-5|Fable 5" \
    "claude-opus-5|Opus 5" \
    "claude-sonnet-5|Sonnet 5" \
    "claude-haiku-4-5-20251001|Haiku 4.5"
  exit 0
fi

model_flags=()
if [ -n "${COMPUTER_MODEL:-}" ] && [ "$COMPUTER_MODEL" != "default" ]; then
  model_flags=(--model "$COMPUTER_MODEL")
fi

mapfile -t allow < <(jq -r '.permissions.allow[]' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

# Working directories beyond $HOME. The agent is confined to its working
# directories no matter what allowedTools says, so reading anything under
# /run, /var or another user-approved root needs an explicit --add-dir.
# Dir(...) grants approved in the panel land here.
add_flags=()
while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] && add_flags+=(--add-dir "$dir")
done < <(jq -r '.permissions.additionalDirectories[]?' "$COMPUTER_SETTINGS_FILE" 2>/dev/null)

# Events → activity lines (for the panel's live log) + the final answer.
# Everything is clipped here rather than in the panel so a runaway command
# or a huge tool result can never bloat the log file.
stream_filter='
  def clip($n): tostring | if length > $n then .[0:$n] + "…" else . end;
  def detail: .input as $i
    | ($i.description // $i.command // $i.file_path // $i.pattern
       // $i.url // $i.query // $i.prompt // "") | clip(160);
  def text_of: if type == "string" then .
    elif type == "array" then (map(.text? // "") | join(" "))
    else "" end;
  if .type == "assistant" then
    (
      .message.content[]?
      | if .type == "tool_use" then
          "A " + ({kind: "tool", label: .name, detail: detail} | tojson)
        elif .type == "text" and ((.text // "") | test("\\S")) then
          "A " + ({kind: "text", label: "", detail: (.text | clip(400))} | tojson)
        else empty end
    ),
    (
      # Per-call token usage. ctx is what this call actually carried, which
      # is the number that grows as a conversation gets long.
      .message.usage
      | select(. != null)
      | "A " + ({kind: "usage",
                 ctx: ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
                       + (.cache_creation_input_tokens // 0)),
                 out: (.output_tokens // 0)} | tojson)
    )
  elif .type == "user" then
    .message.content[]?
    | select(.type == "tool_result")
    | "A " + ({kind: (if .is_error then "error" else "result" end), label: "",
               detail: (.content | text_of | gsub("\\s+"; " ") | clip(200))} | tojson)
  elif .type == "rate_limit_event" then
    .rate_limit_info.unifiedWindows
    | select(. != null)
    | "A " + ({kind: "limits",
               five_hour: (.five_hour.utilization // null),
               seven_day: (.seven_day.utilization // null),
               resets: (.five_hour.resetsAt // null)} | tojson)
  elif .type == "system" and .subtype == "init" then
    "A " + ({kind: "meta", label: "session", detail: (.model // "")} | tojson)
  elif .type == "result" then
    (
      # The window comes from whichever model did the most work — a turn can
      # touch a small helper model whose window would understate the real one.
      "A " + ({kind: "summary",
               tout: (.usage.output_tokens // 0),
               cread: (.usage.cache_read_input_tokens // 0),
               cost: (.total_cost_usd // 0),
               window: ([(.modelUsage // {}) | to_entries | .[]
                         | {w: (.value.contextWindow // 0),
                            o: (.value.outputTokens // 0)}]
                        | sort_by(.o) | last | .w // 0),
               session: ((.session_id // "") | .[0:8])} | tojson)
    ),
    ( "R " + ((.result // "") | @base64) )
  else empty end'

note() {  # kind, detail — an activity line from the adapter itself
  [ -n "${COMPUTER_ACTIVITY_FILE:-}" ] || return 0
  jq -cn --arg k "$1" --arg d "$2" '{kind: $k, label: "", detail: $d}' \
    >> "$COMPUTER_ACTIVITY_FILE" 2>/dev/null || true
}

# Runs one claude invocation, streaming activity as it goes. Success is
# defined by the result event carrying an answer, not by the exit code —
# that is the only thing the caller (and the voice) actually needs.
run_turn() {
  local answer="" got=0 line
  while IFS= read -r line; do
    case "$line" in
      "A "*)
        [ -n "${COMPUTER_ACTIVITY_FILE:-}" ] &&
          printf '%s\n' "${line#A }" >> "$COMPUTER_ACTIVITY_FILE"
        ;;
      "R "*)
        answer=$(printf '%s' "${line#R }" | base64 -d 2>/dev/null)
        got=1
        ;;
    esac
  done < <(claude "$@" --output-format stream-json --verbose \
    --append-system-prompt "$COMPUTER_INSTRUCTIONS" \
    --chrome --allowedTools "${allow[@]}" "mcp__claude-in-chrome__.*" \
    "${add_flags[@]+"${add_flags[@]}"}" "${model_flags[@]+"${model_flags[@]}"}" \
    2>/dev/null | jq -r --unbuffered "$stream_filter" 2>/dev/null)
  [ "$got" = 1 ] && [ -n "$answer" ] || return 1
  printf '%s\n' "$answer"
}

if [ "$COMPUTER_CONV_STARTED" = "1" ]; then
  run_turn -p "$1" --resume "$COMPUTER_CONV_ID" && exit 0
  # Continuity lost — never fail the turn over it; start clean and say so
  # in the log so a surprising loss of context is visible in the panel.
  note meta "resume failed — starting a fresh conversation"
fi
run_turn -p "$1" --session-id "$COMPUTER_CONV_ID"
