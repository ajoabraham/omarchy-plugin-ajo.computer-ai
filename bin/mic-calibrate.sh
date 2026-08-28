#!/usr/bin/env bash
# Voice-driven microphone calibration. The assistant runs this during a live
# conversation to measure and tune the mic, so the user can just say "help me
# fix my microphone" and be walked through it out loud.
#
# The trick that makes this conversational: the panel already records every
# turn to a PCM file before transcribing it, so `analyze` reads the audio of
# the sentence the user JUST spoke — no fragile "speak now" capture, every
# turn is a fresh sample. Levels are in dBFS (0 = clipping, quieter = more
# negative), the same scale the panel's endpointer uses.
#
# Two things get tuned:
#   - mic gain: a system setting (wpctl), so it survives reboots but is not
#     part of the plugin.
#   - speechThresholdDb / endSilenceMs: written to ~/.config/omarchy/
#     computer.json; the panel re-reads them at the start of the next turn,
#     so a change takes effect WITHOUT closing the panel or the conversation.
#
# Subcommands:
#   status                    current gain, device, thresholds, noise floor
#   analyze [pcm] [secs]      measure the last turn's audio (default) or a
#                             fresh N-second capture; print stats + advice
#   set-gain <0.0..3.0>       set mic input gain
#   set-threshold <dBFS>      voice-activity threshold (clamped -70..-20)
#   set-silence <ms>          end-of-speech silence window (clamped 800..5000)
#   auto                      measure last turn's audio and pick a gain
#
# Not pre-approved: it changes system audio and listening behaviour, so it
# runs behind a one-time panel grant like the other privileged helpers here.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$HOME/.config/omarchy/computer.json"
recfile="${XDG_RUNTIME_DIR:-/tmp}/computer-ai-question.wav"
src='@DEFAULT_AUDIO_SOURCE@'

die() { echo "mic-calibrate: $*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }
have wpctl || die "wpctl (pipewire) not found"
have ffmpeg || die "ffmpeg not found"

cfg_num() { jq -r --arg k "$1" '.[$k] // empty' "$cfg" 2>/dev/null; }
gain_now() { wpctl get-volume "$src" 2>/dev/null | awk '{print $2}'; }
dev_now()  { wpctl inspect "$src" 2>/dev/null | sed -n 's/.*node.description = "\(.*\)"/\1/p' | head -1; }

# RMS-per-50ms distribution of a raw PCM file — the endpointer's own view.
# Prints: frames p10 median p90 max peak(dBFS)
stats() {
  local pcm="$1"
  [ -s "$pcm" ] || { echo "0 - - - - -"; return; }
  local rms peak
  rms=$(ffmpeg -hide_banner -nostats -loglevel error -f s16le -ar 16000 -ac 1 -i "$pcm" \
    -af "asetnsamples=800,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
    -f null - 2>/dev/null \
    | awk -F= '/RMS_level/{v=$2; if(v=="-inf")v=-90; print v}' \
    | sort -n \
    | awk '{a[NR]=$1} END{ if(!NR){print "0 - - - -"; exit}
        printf "%d %.1f %.1f %.1f %.1f", NR, a[int(NR*0.1)+1], a[int(NR*0.5)+1], a[int(NR*0.9)+1], a[NR] }')
  peak=$(ffmpeg -hide_banner -f s16le -ar 16000 -ac 1 -i "$pcm" -af volumedetect -f null - 2>&1 \
    | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB/\1/p' | head -1)
  echo "$rms ${peak:--}"
}

cmd="${1:-status}"
case "$cmd" in
  status)
    thr=$(cfg_num mic_threshold_db); sil=$(cfg_num mic_end_silence_ms)
    echo "device:    $(dev_now)"
    echo "gain:      $(gain_now)   (0.0-3.0; 1.0 = 100%)"
    echo "threshold: ${thr:--50 (default)} dBFS   silence-window: ${sil:-2200 (default)} ms"
    ;;

  analyze|auto)
    secs="${3:-}"
    if [ "${2:-last}" = "fresh" ]; then
      pcm=$(mktemp); trap 'rm -f "$pcm"' EXIT
      "$script_dir/record.sh" "$pcm" "${secs:-5}" >/dev/null 2>&1
      srclabel="a fresh ${secs:-5}s capture"
    else
      pcm="${2:-$recfile}"
      [ "$pcm" = "last" ] && pcm="$recfile"
      srclabel="the last turn's audio"
    fi
    [ -s "$pcm" ] || die "no audio to analyze at $pcm (speak a turn first, or use: analyze fresh 5)"

    read -r frames p10 med p90 max peak < <(stats "$pcm")
    [ "$frames" -gt 0 ] 2>/dev/null || die "capture was empty"
    gain=$(gain_now)
    echo "source:    $srclabel  ($frames frames, gain $gain)"
    echo "speech:    median ${med}  loud(p90) ${p90}  peak ${peak} dBFS"

    # Judge against the same scale the endpointer uses. Peaks near 0 clip
    # (bad for transcription); loud speech should sit ~25 dB above the
    # threshold so between-word dips never read as a pause.
    verdict=""; suggest=""
    awk_cmp() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 > b+0)}'; }
    if awk_cmp "$peak" "-1.5"; then
      verdict="TOO HOT — peaks are clipping, which garbles transcription."
      newg=$(awk -v g="$gain" 'BEGIN{printf "%.2f", (g<=0?1:g)*0.6}')
      suggest="set-gain $newg"
    elif awk_cmp "-30" "$p90"; then
      verdict="TOO QUIET — even loud speech barely clears the threshold."
      newg=$(awk -v g="$gain" 'BEGIN{ng=(g<=0?1:g)*2.2; if(ng>3)ng=3; printf "%.2f", ng}')
      suggest="set-gain $newg"
    else
      verdict="GOOD — loud speech is well above the threshold with peak headroom."
    fi
    echo "verdict:   $verdict"
    [ -n "$suggest" ] && echo "suggest:   mic-calibrate.sh $suggest   (then ask the user to speak again to re-check)"
    if [ "$cmd" = auto ] && [ -n "$suggest" ]; then
      newg="${suggest#set-gain }"
      wpctl set-volume "$src" "$newg" && echo "applied:   gain -> $(gain_now)"
    fi
    ;;

  set-gain)
    v="${2:-}"; [ -n "$v" ] || die "usage: set-gain <0.0..3.0>"
    v=$(awk -v x="$v" 'BEGIN{ if(x<0)x=0; if(x>3)x=3; printf "%.2f", x}')
    wpctl set-volume "$src" "$v" || die "wpctl failed"
    echo "gain -> $(gain_now)"
    ;;

  set-threshold)
    v="${2:-}"; [ -n "$v" ] || die "usage: set-threshold <dBFS, e.g. -50>"
    v=$(awk -v x="$v" 'BEGIN{ if(x>-20)x=-20; if(x<-70)x=-70; printf "%d", x}')
    "$script_dir/config-set.sh" mic_threshold_db "$v"
    echo "threshold -> ${v} dBFS (applies from your next turn)"
    ;;

  set-silence)
    v="${2:-}"; [ -n "$v" ] || die "usage: set-silence <ms, e.g. 2200>"
    v=$(awk -v x="$v" 'BEGIN{ if(x<800)x=800; if(x>5000)x=5000; printf "%d", x}')
    "$script_dir/config-set.sh" mic_end_silence_ms "$v"
    echo "silence-window -> ${v} ms (applies from your next turn)"
    ;;

  *)
    die "unknown command '$cmd' (status|analyze|auto|set-gain|set-threshold|set-silence)"
    ;;
esac
