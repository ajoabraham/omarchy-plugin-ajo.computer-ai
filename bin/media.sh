#!/usr/bin/env bash
# Volume, mute and transport control — the two CLIs behind a fixed verb set.
#
# Replaces `Bash(wpctl:*)` and `Bash(playerctl:*)`: wpctl can reconfigure or
# silence any node on the graph (including the microphone, which matters for
# an assistant that listens), and playerctl can open arbitrary player URIs.
# The verbs below are the ones a voice assistant actually needs.
#
#   media.sh volume up|down|mute|unmute|toggle|<0-150>
#   media.sh mic mute|unmute|toggle
#   media.sh player play|pause|toggle|next|previous|stop|status
set -u

SINK="@DEFAULT_AUDIO_SINK@"
SOURCE="@DEFAULT_AUDIO_SOURCE@"

usage() {
  cat >&2 <<'USAGE'
usage: media.sh volume up|down|mute|unmute|toggle|<0-150>
       media.sh mic mute|unmute|toggle
       media.sh player play|pause|toggle|next|previous|stop|status
USAGE
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "media: $1 is not installed" >&2; exit 127; }; }

case "${1:-}" in
  volume)
    need wpctl
    case "${2:-}" in
      up)      exec wpctl set-volume -l 1.5 "$SINK" 5%+ ;;
      down)    exec wpctl set-volume "$SINK" 5%- ;;
      mute)    exec wpctl set-mute "$SINK" 1 ;;
      unmute)  exec wpctl set-mute "$SINK" 0 ;;
      toggle)  exec wpctl set-mute "$SINK" toggle ;;
      ''|*[!0-9]*) usage; exit 2 ;;
      *)
        # An absolute level, clamped — not a free-form wpctl argument.
        [ "$2" -le 150 ] || { echo "media: volume must be 0-150" >&2; exit 2; }
        exec wpctl set-volume -l 1.5 "$SINK" "$2%"
        ;;
    esac
    ;;

  mic)
    need wpctl
    case "${2:-}" in
      mute)   exec wpctl set-mute "$SOURCE" 1 ;;
      unmute) exec wpctl set-mute "$SOURCE" 0 ;;
      toggle) exec wpctl set-mute "$SOURCE" toggle ;;
      *) usage; exit 2 ;;
    esac
    ;;

  player)
    need playerctl
    case "${2:-}" in
      play|pause|next|previous|stop|status) exec playerctl "$2" ;;
      toggle) exec playerctl play-pause ;;
      *) usage; exit 2 ;;
    esac
    ;;

  *)
    usage
    exit 2
    ;;
esac
