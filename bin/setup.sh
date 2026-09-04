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
echo "Optional — email (draft/send from your Gmail):"
command -v himalaya   >/dev/null 2>&1 && ok "himalaya (email CLI)" || note "himalaya — for email: pacman -S himalaya"
command -v secret-tool >/dev/null 2>&1 && ok "secret-tool (keyring)" || note "secret-tool — for email credentials: pacman -S libsecret"

echo
echo "Agent harnesses (need at least one):"
export PATH="$HOME/.local/share/mise/shims:$HOME/.grok/bin:$HOME/.local/bin:$PATH"
found_agent=0
command -v claude >/dev/null 2>&1 && { ok "claude (Claude Code)"; found_agent=1; } || bad "claude — https://claude.com/claude-code"
command -v grok   >/dev/null 2>&1 && { ok "grok (Grok CLI)"; found_agent=1; }   || bad "grok — optional"
command -v codex  >/dev/null 2>&1 && { ok "codex (ChatGPT — run 'codex login' once)"; found_agent=1; } || bad "codex — optional"
[ "$found_agent" = 1 ] || missing=1

# --- verified third-party artifacts ----------------------------------------
#
# Everything downloaded here is named in defaults/artifacts.json by immutable
# identity (a release tag, a Hugging Face commit revision) and checked
# against a digest recorded in that file before it is used. The previous
# version fetched a tarball and two model files from mutable URLs and piped
# the archive straight into `tar xzf` in the data directory — so the bytes
# that ran on the user's machine were whatever those URLs served that day,
# unpacked to wherever the archive asked.
manifest="$plugin_dir/defaults/artifacts.json"

fetch_verified() { # $1 url, $2 expected sha256, $3 destination path
  local url="$1" want="$2" out="$3" got
  # -q ignores ~/.curlrc; https only, no redirect off the scheme.
  curl -q -sfL --proto '=https' --proto-redir '=https' --max-redirs 5 \
       --connect-timeout 15 --max-time 900 -o "$out" "$url" || {
    bad "download failed: $url"; return 1; }
  got=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then
    bad "digest mismatch for $url"
    note "expected $want"
    note "got      $got"
    rm -f "$out"
    return 1
  fi
  return 0
}

install_tts() {
  command -v jq >/dev/null 2>&1 || { bad "jq is required to verify downloads"; return 1; }
  [ -f "$manifest" ] || { bad "missing $manifest"; return 1; }

  local stage piper_url piper_sha voice_url voice_sha cfg_url cfg_sha voice_name
  piper_url=$(jq -r '.piper.url' "$manifest")
  piper_sha=$(jq -r '.piper.sha256' "$manifest")
  voice_name=$(jq -r '.voice.name' "$manifest")
  voice_url=$(jq -r '.voice.model.url' "$manifest")
  voice_sha=$(jq -r '.voice.model.sha256' "$manifest")
  cfg_url=$(jq -r '.voice.config.url' "$manifest")
  cfg_sha=$(jq -r '.voice.config.sha256' "$manifest")

  # Staged privately inside the data directory, so a half-finished download
  # is never visible as an installed engine and the final move is a rename
  # on the same filesystem.
  mkdir -p "$data_dir/voices"
  chmod 700 "$data_dir" 2>/dev/null || true
  stage=$(umask 077; mktemp -d "$data_dir/.stage.XXXXXX") || return 1
  trap 'rm -rf "$stage"' RETURN

  fetch_verified "$piper_url" "$piper_sha" "$stage/piper.tar.gz" || return 1
  # Members are validated against traversal and escaping links before a
  # single byte is written (bin/unpack-archive.py).
  python3 "$plugin_dir/bin/unpack-archive.py" "$stage/piper.tar.gz" "$stage/unpacked" >/dev/null || {
    bad "piper archive failed validation"; return 1; }
  [ -x "$stage/unpacked/piper/piper" ] || { bad "piper archive did not contain piper/piper"; return 1; }

  fetch_verified "$voice_url" "$voice_sha" "$stage/$voice_name.onnx" || return 1
  fetch_verified "$cfg_url" "$cfg_sha" "$stage/$voice_name.onnx.json" || return 1

  rm -rf "$data_dir/piper"
  mv "$stage/unpacked/piper" "$data_dir/piper" || return 1
  mv "$stage/$voice_name.onnx" "$data_dir/voices/$voice_name.onnx" || return 1
  mv "$stage/$voice_name.onnx.json" "$data_dir/voices/$voice_name.onnx.json" || return 1
  return 0
}

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
    if install_tts; then
      ok "Piper installed with voice $(jq -r '.voice.name' "$manifest")"
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
echo "Bar widget:"
# The assistant is a bar widget now (an icon with a drop-down panel), not a
# floating window — so there is no window rule to add. Enable it and drop it
# into the bar's right section.
if omarchy plugin list 2>/dev/null | grep -q "ajo.computer-ai"; then ok "plugin discovered"
else note "run 'omarchy-shell shell rescanPlugins' if the icon doesn't appear"; fi
if [ "$wire" = 1 ]; then
  omarchy plugin enable ajo.computer-ai right >/dev/null 2>&1 \
    && ok "enabled and placed in the bar (right section)" \
    || note "enable it yourself: omarchy plugin enable ajo.computer-ai right"
else
  note "place it with: omarchy plugin enable ajo.computer-ai right"
  note "(or move it later: omarchy bar move ajo.computer-ai <left|center|right>)"
fi

echo
echo "Hyprland wiring:"
bindings="$HOME/.config/hypr/bindings.lua"
bind_line="o.bind(\"End\", \"Computer\", os.getenv(\"HOME\") .. \"/.config/omarchy/plugins/ajo.computer-ai/bin/summon.sh\")"
need_bind=1
grep -q "ajo.computer-ai/bin/summon.sh" "$bindings" 2>/dev/null && { ok "summon keybinding present"; need_bind=0; }
if [ "$need_bind" = 1 ]; then
  if [ "$wire" = 1 ]; then
    printf '\n-- Computer AI: summon listening (End = Fn+Right on most laptops).\n%s\n' "$bind_line" >> "$bindings" && ok "added keybinding to $bindings"
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1
  else
    bad "not wired — add this (or rerun with --wire):"
    note "$bindings: $bind_line"
  fi
fi

echo
if [ "$missing" = 0 ]; then
  echo "All set. The icon is in your bar — click it, or press End, and speak."
else
  echo "Some items need attention above; rerun setup after fixing them."
fi
