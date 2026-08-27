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

Additionally, `<name>.sh --list-models` must print the selectable models,
one `value|Label` per line, best/latest first — the first line is used as
the default when the user hasn't picked one, and the panel's Model dropdown
is built from this list.

The adapter prints the spoken answer on stdout (plain text) and exits 0 on
success. It owns its harness's specifics: how to pass the system prompt, how
to map the permission policy, and how to resume `COMPUTER_CONV_ID` across
turns (fall back to a fresh session if resume fails — never fail the turn
just because continuity was lost).
