# Agent adapters

Every `<name>.sh` in this directory is a harness the Computer AI panel can
use; the Assistant dropdown lists them automatically. Adding an agent is
just dropping an executable script here.

## Contract

An adapter is called as `<name>.sh "<question>"` with this environment:

| Variable                 | Meaning                                          |
|--------------------------|--------------------------------------------------|
| `COMPUTER_INSTRUCTIONS`  | System-prompt text (persona, powers, memory)     |
| `COMPUTER_SETTINGS_FILE` | JSON permission policy (`.permissions.allow[]`)  |
| `COMPUTER_CONV_ID`       | Conversation UUID for this panel session         |
| `COMPUTER_CONV_STARTED`  | `1` if this conversation has previous turns      |
| `COMPUTER_STATE_DIR`     | Scratch/state directory for adapter bookkeeping  |
| `COMPUTER_MODEL`         | Model to use; `default` = harness's own default  |
| `COMPUTER_ACTIVITY_FILE` | Optional live progress log (see below)           |

Additionally, `<name>.sh --list-models` must print the selectable models,
one `value|Label` per line, best/latest first — the first line is used as
the default when the user hasn't picked one, and the panel's Model dropdown
is built from this list.

## Activity log (optional)

A turn can take minutes, and a panel that shows nothing until the voice
comes back looks hung. An adapter that can see its harness work should
append one JSON object per line to `COMPUTER_ACTIVITY_FILE` as it goes:

```json
{"kind": "tool", "label": "Bash", "detail": "List cached camera frames"}
```

`kind` is one of `tool` (about to run something), `result` (what came
back), `error` (a failed tool), `text` (the agent's own narration), or
`meta` (session notes). `label` is a short name, `detail` a one-line
summary — clip long values in the adapter, not the panel. The panel tails
the file live and shows the newest line under the orb, with the whole log
behind Ctrl+I. `bin/ask.sh` truncates the file before each turn.

Three further kinds carry numbers instead of steps. They update the
drawer's status strip and never appear as log rows:

| Kind      | Fields                                          | When        |
|-----------|-------------------------------------------------|-------------|
| `usage`   | `ctx` (tokens the last call carried)            | per call    |
| `limits`  | `five_hour`, `seven_day` (0–1), `resets` (epoch) | if reported |
| `summary` | `tout`, `cread`, `cost`, `window`, `session`     | end of turn |

Only report an output-token count in `summary`. Harnesses commonly stream
a *partial* usage snapshot per message that does not sum to the turn
total, so a running tally built from those is confidently wrong — the
panel deliberately ignores per-message output counts for that reason.

Adapters that cannot stream simply ignore the variable; they just show as
a spinning orb with no detail. `claude.sh` is the worked example — it runs
`--output-format stream-json` and turns each event into a line.

## Answering

The adapter prints the spoken answer on stdout (plain text) and exits 0 on
success. It owns its harness's specifics: how to pass the system prompt, how
to map the permission policy, and how to resume `COMPUTER_CONV_ID` across
turns (fall back to a fresh session if resume fails — never fail the turn
just because continuity was lost).
