#!/usr/bin/env bash
# One-time setup for Computer AI. `omarchy plugin add` only clones the repo —
# it never runs plugin code — so run this once after installing:
#
#   bash ~/.config/omarchy/plugins/ajo.computer-ai/bin/setup.sh [--wire] [--no-tts]
#
# It checks dependencies, downloads a starter TTS voice when none is present
# (skip with --no-tts), seeds the permission policy, and prints the Hyprland
# wiring — or appends it for you with --wire.
set -u
plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
data_dir="$HOME/.local/share/computer-ai"
settings_file="$data_dir/claude-settings.json"
wire=0
no_tts=0
for arg in "$@"; do
  case "$arg" in
    --wire) wire=1 ;;
    --no-tts) no_tts=1 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

missing=0

echo "Computer AI setup"
echo
echo "Required commands:"
for cmd in ffmpeg jq pw-play uuidgen; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"
  else bad "$cmd — install with: omarchy pkg add ${cmd/pw-play/pipewire}"; missing=1; fi
done
if command -v voxtype >/dev/null 2>&1; then ok "voxtype (speech-to-text)"
else bad "voxtype — install with: omarchy voxtype install"; missing=1; fi

echo
echo "Agent harnesses (need at least one):"
export PATH="$HOME/.local/share/mise/shims:$HOME/.grok/bin:$HOME/.local/bin:$PATH"
found_agent=0
command -v claude >/dev/null 2>&1 && { ok "claude (Claude Code)"; found_agent=1; } || bad "claude — https://claude.com/claude-code"
command -v grok   >/dev/null 2>&1 && { ok "grok (Grok CLI)"; found_agent=1; }   || bad "grok — optional"
command -v codex  >/dev/null 2>&1 && { ok "codex (ChatGPT — run 'codex login' once)"; found_agent=1; } || bad "codex — optional"
[ "$found_agent" = 1 ] || missing=1

echo
echo "Text-to-speech:"
have_tts=0
[ -x "$data_dir/piper/piper" ] && { ok "Piper at $data_dir/piper"; have_tts=1; }
[ -f "$data_dir/kokoro/kokoro-v1.0.onnx" ] && { ok "Kokoro at $data_dir/kokoro"; have_tts=1; }
if [ "$have_tts" = 0 ]; then
  if [ "$no_tts" = 1 ]; then
    bad "no TTS engine — responses will be text-only (rerun without --no-tts)"
  else
    echo "  downloading Piper + one voice (~90MB) to $data_dir ..."
    mkdir -p "$data_dir/voices"
    if (cd "$data_dir" \
        && curl -sfLO https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz \
        && tar xzf piper_linux_x86_64.tar.gz && rm piper_linux_x86_64.tar.gz \
        && cd voices \
        && curl -sfLO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx \
        && curl -sfLO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx.json); then
      ok "Piper installed with voice en_GB-northern_english_male-medium"
      note "more voices: https://huggingface.co/rhasspy/piper-voices (drop .onnx + .json into $data_dir/voices)"
      note "for the nicer Kokoro engine, see bin/speak.sh and bin/kokoro-say.py"
    else
      bad "TTS download failed — check network and rerun"; missing=1
    fi
  fi
fi

echo
echo "Permission policy:"
if [ -f "$settings_file" ]; then ok "$settings_file"
else
  mkdir -p "$data_dir"
  sed "s|__PLUGIN_DIR__|$plugin_dir|g" "$plugin_dir/defaults/permissions.json" > "$settings_file"
  ok "seeded default policy to $settings_file"
fi

echo
echo "Hyprland wiring:"
bindings="$HOME/.config/hypr/bindings.lua"
hyprlua="$HOME/.config/hypr/hyprland.lua"
bind_line="o.bind(\"End\", \"Computer\", os.getenv(\"HOME\") .. \"/.config/omarchy/plugins/ajo.computer-ai/bin/summon.sh\")"
rule_line="o.window({ class = \"^(org\\\\.quickshell)\$\", title = \"^(Computer)\$\" }, { float = true, center = true })"
need_bind=1; need_rule=1
grep -q "ajo.computer-ai/bin/summon.sh" "$bindings" 2>/dev/null && { ok "summon keybinding present"; need_bind=0; }
grep -q 'title = "\^(Computer)\$"' "$hyprlua" 2>/dev/null && { ok "float rule present"; need_rule=0; }
if [ "$need_bind" = 1 ] || [ "$need_rule" = 1 ]; then
  if [ "$wire" = 1 ]; then
    [ "$need_bind" = 1 ] && printf '\n-- Computer AI: summon listening (End = Fn+Right on most laptops).\n%s\n' "$bind_line" >> "$bindings" && ok "added keybinding to $bindings"
    [ "$need_rule" = 1 ] && printf '\n-- Computer AI: float the panel window.\n%s\n' "$rule_line" >> "$hyprlua" && ok "added float rule to $hyprlua"
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1
  else
    bad "not wired — add these (or rerun with --wire):"
    [ "$need_bind" = 1 ] && note "$bindings: $bind_line"
    [ "$need_rule" = 1 ] && note "$hyprlua: $rule_line"
  fi
fi

echo
if [ "$missing" = 0 ]; then
  echo "All set. Enable with: omarchy plugin enable ajo.computer-ai — then press your hotkey and speak."
else
  echo "Some items need attention above; rerun setup after fixing them."
fi
