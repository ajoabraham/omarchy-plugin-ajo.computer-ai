# Computer AI

![Computer AI — voice assistant panel for Omarchy](preview.png)

A Jarvis-style voice assistant plugin for the [Omarchy](https://omarchy.org)
shell. Press a hotkey, speak, and a pluggable AI agent answers aloud — and
can operate the desktop (launch apps, drive the browser, set reminders,
control media) within a user-approved permission policy.

- **Orb UI**: audio-reactive particle swarm (a port of the omarchyplugins.com
  parametric canvas) with live mic levels while listening, speech-synced
  playback animation, and mood morphs per phase.
- **Shows its work**: an agent turn can run for minutes, so while it works
  the voice bars retract and the *gyre* takes the ring — sweeping arcs, an
  elapsed clock, and the newest step the agent took, with a sonar ping on
  every tool call. `Ctrl+I` opens the full step-by-step log, plus tokens,
  cost and account usage — kept off the face of the panel so the orb
  stays uncluttered.
- **Pipeline**: ffmpeg capture with voice-activity endpointing → Voxtype
  (whisper) transcription → agent harness → Kokoro/Piper TTS.
- **Mic calibration by voice**: say "help me tune my microphone" and the
  agent walks it out loud. It measures the audio of the sentence you *just
  spoke* — no "speak now" cue, every turn is a sample — reports the level
  (too hot, too quiet, good) and adjusts mic gain and the endpointing
  thresholds. Threshold and silence-window changes take effect on your next
  sentence, without restarting the shell or closing the panel.
- **Agents**: one adapter script per harness in `agents/` (Claude Code, Grok
  CLI, ChatGPT via Codex CLI ship in-tree). The panel's Assistant dropdown
  discovers them automatically; see `agents/README.md` for the contract.
- **Conversations**: threaded per panel session with a 10-minute grace
  window; "start a new conversation" resets on demand.
- **Memory**: persistent markdown memory in `~/.local/share/computer-ai/memory/`
  (index inlined into every turn).
- **Local web fetch** (optional): `bin/localfetch.sh` retrieves a page from
  this machine over your own connection, rather than through the harness
  vendor's servers — so sites resolve and geo-vary as they do for you, and
  the LAN, router and localhost are reachable too. No JavaScript. Behind a
  one-time grant.
- **Permissions**: allowlist in `~/.local/share/computer-ai/claude-settings.json`.
  The agent can request new grants — tool rules, or `Dir(/path)` to reach
  outside `$HOME` — and you approve them on a card in the panel.

## Install

```bash
omarchy plugin add https://github.com/ajoabraham/omarchy-plugin-ajo.computer-ai
# (or for development: clone and symlink)
# ln -s /path/to/computer-ai ~/.config/omarchy/plugins/ajo.computer-ai

# Installing never runs plugin code, so run setup once — it checks
# dependencies, downloads a starter TTS voice, seeds the permission
# policy, and (with --wire) adds the Hyprland keybinding + float rule:
bash ~/.config/omarchy/plugins/ajo.computer-ai/bin/setup.sh --wire

omarchy plugin enable ajo.computer-ai
```

Dependencies (setup.sh checks them all): `voxtype`
(`omarchy voxtype install`), `ffmpeg`, `jq`, pipewire (`pw-play`), and at
least one agent CLI (`claude`, `grok`, or `codex`). Local web fetch also
uses `curl` and `python3`, both already present on Omarchy. TTS lives in
`~/.local/share/computer-ai/` — setup fetches Piper plus one voice; more Piper
voices and the nicer Kokoro engine are documented in `bin/speak.sh`.

The Hyprland wiring setup adds (or prints, without `--wire`):

```lua
-- bindings.lua — summon on a key (End = Fn+Right on most laptops)
o.bind("End", "Computer", os.getenv("HOME") .. "/.config/omarchy/plugins/ajo.computer-ai/bin/summon.sh")

-- hyprland.lua — float the panel window
o.window({ class = "^(org\\.quickshell)$", title = "^(Computer)$" }, { float = true, center = true })
```

## Security & privilege boundaries

Like all Omarchy shell plugins, this runs unsandboxed with your user
permissions — and unlike most, it drives AI agent CLIs that can execute
commands. Know the boundaries:

- Agents run headless under an **allowlist** seeded from
  `defaults/permissions.json` into `~/.local/share/computer-ai/claude-settings.json`:
  desktop actions (`omarchy`, `xdg-open`, `uwsm-app`, `hyprctl`), media/
  notification/clipboard tools, read-only system info, web lookup, and their
  own memory directory. Everything else is denied.
- Agents are also confined to `$HOME` as their working directory, whatever
  the allowlist says. Reaching a runtime or state directory elsewhere needs
  a separate `Dir(/absolute/path)` grant, which lands in
  `permissions.additionalDirectories` and becomes `--add-dir`.
- Escalation is human-gated: an agent may *request* a rule
  (`bin/request-grant.sh`), but only you can approve it, on a card in the
  panel. Grants are permanent until you remove the line from the settings
  file. The system prompt forbids requesting broad rules, sudo, or writes
  outside the plugin's own data directories.
- The activity log is local: `~/.local/share/computer-ai/state/activity.jsonl`,
  truncated at the start of every turn. It holds clipped one-line summaries
  of tool calls, so treat it like scrollback, not like a secret store.
- Browser control (Claude harness) touches your real, logged-in Chromium and
  additionally requires a one-time automation grant in the Claude browser
  extension, where per-site limits are also available. The ChatGPT harness
  runs in Codex's read-only sandbox and takes no actions.
- Web fetches normally run on the agent harness's own infrastructure.
  `bin/localfetch.sh` runs them from here instead — which is the point, since
  a page then sees your address and region — but it also means it reaches what
  only this machine can: localhost, the LAN, the router. That is strictly
  wider than the built-in tool, so it is deliberately absent from the default
  allowlist — the agent must request it and you approve it once on the panel
  card. It is pinned to http/https across redirects, capped in size and time,
  and prints the address each fetch resolved to, so a local-network fetch is
  visible in the activity log rather than silent.
- Voice is an input channel: anything the assistant is permitted to do, a
  misheard phrase could trigger. Keep the allowlist as narrow as you can
  live with.
- Audio is processed locally (Voxtype/whisper STT, Piper/Kokoro TTS);
  transcribed text goes only to the agent CLI you selected.

## Uninstall

```bash
omarchy plugin remove ajo.computer-ai
```

removes the plugin cleanly. Optional leftovers you may also delete:
`~/.local/share/computer-ai/` (voices, memory, permission policy, state),
`~/.config/omarchy/computer.json`, and the two Hyprland lines that
`setup.sh --wire` added.

## Controls

Enter — speak / send / interrupt · Esc — close · Super+drag — move ·
Ctrl+I — show/hide the activity log · A / D — approve / deny a permission
request · Settings drawer — agent + voice.
