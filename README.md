# Computer AI

A Jarvis-style voice assistant plugin for the [Omarchy](https://omarchy.org)
shell. Press a hotkey, speak, and a pluggable AI agent answers aloud — and
can operate the desktop (launch apps, drive the browser, set reminders,
control media) within a user-approved permission policy.

- **Orb UI**: audio-reactive particle swarm (a port of the omarchyplugins.com
  parametric canvas) with live mic levels while listening, speech-synced
  playback animation, and mood morphs per phase.
- **Pipeline**: ffmpeg capture with voice-activity endpointing → Voxtype
  (whisper) transcription → agent harness → Kokoro/Piper TTS.
- **Agents**: one adapter script per harness in `agents/` (Claude Code, Grok
  CLI, ChatGPT via Codex CLI ship in-tree). The panel's Assistant dropdown
  discovers them automatically; see `agents/README.md` for the contract.
- **Conversations**: threaded per panel session with a 10-minute grace
  window; "start a new conversation" resets on demand.
- **Memory**: persistent markdown memory in `~/.local/share/computer/memory/`
  (index inlined into every turn).
- **Permissions**: allowlist in `~/.local/share/computer/claude-settings.json`.
  The agent can request new grants; you approve them on a card in the panel.

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
least one agent CLI (`claude`, `grok`, or `codex`). TTS lives in
`~/.local/share/computer/` — setup fetches Piper plus one voice; more Piper
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
  `defaults/permissions.json` into `~/.local/share/computer/claude-settings.json`:
  desktop actions (`omarchy`, `xdg-open`, `uwsm-app`, `hyprctl`), media/
  notification/clipboard tools, read-only system info, web lookup, and their
  own memory directory. Everything else is denied.
- Escalation is human-gated: an agent may *request* a rule
  (`bin/request-grant.sh`), but only you can approve it, on a card in the
  panel. Grants are permanent until you remove the line from the settings
  file. The system prompt forbids requesting broad rules, sudo, or writes
  outside the plugin's own data directories.
- Browser control (Claude harness) touches your real, logged-in Chromium and
  additionally requires a one-time automation grant in the Claude browser
  extension, where per-site limits are also available. The ChatGPT harness
  runs in Codex's read-only sandbox and takes no actions.
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
`~/.local/share/computer/` (voices, memory, permission policy, state),
`~/.config/omarchy/computer.json`, and the two Hyprland lines that
`setup.sh --wire` added.

## Controls

Enter — speak / send / interrupt · Esc — close · Super+drag — move ·
A / D — approve / deny a permission request · Settings drawer — agent + voice.
