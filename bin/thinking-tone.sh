#!/usr/bin/env bash
# Ambient "thinking" tone — a soft, evolving generative pad streamed live to
# the audio sink while the agent works. One of four moods (aurora, nebula,
# umbra, crystal) is chosen at random each time. Killed (SIGTERM) to stop,
# with a quick volume fade-out so it does not cut abruptly into the reply.
#
# Two courtesies: it plays NOTHING if other audio is already going (so it
# never steps on music or a video), and it fades in gently. Volume is low;
# override with COMPUTER_TONE_VOLUME (default 7, applied over a low synth pad).
set -u
command -v ffmpeg >/dev/null 2>&1 || exit 0
command -v pactl  >/dev/null 2>&1 || exit 0

# Don't play over other audio: if any non-corked playback stream exists, bail.
if pactl list sink-inputs 2>/dev/null | grep -q "Corked: no"; then
  exit 0
fi

vol="${COMPUTER_TONE_VOLUME:-7}"
pick="${1:-$(( RANDOM % 4 ))}"
case "$pick" in
  0) name="aurora"; lp=1500; rev="aecho=0.85:0.9:90|150:0.25|0.18"
     L="0.05*(1.0*(0.5+0.5*sin(2*PI*0.05*t+0.0))*sin(2*PI*98.0*t) + 0.7*(0.5+0.5*sin(2*PI*0.061*t+1.0))*sin(2*PI*196.0*t) + 0.35*(0.5+0.5*sin(2*PI*0.037*t+0.0))*sin(2*PI*147.0*t) + 0.3*(0.5+0.5*sin(2*PI*0.053*t+2.0))*sin(2*PI*220.0*t) + 0.28*(0.5+0.5*sin(2*PI*0.041*t+4.0))*sin(2*PI*262.0*t) + 0.24*(0.5+0.5*sin(2*PI*0.067*t+1.0))*sin(2*PI*294.0*t) + 0.2*(0.5+0.5*sin(2*PI*0.047*t+3.0))*sin(2*PI*330.0*t) + 0.14*(0.5+0.5*sin(2*PI*0.029*t+5.0))*sin(2*PI*392.0*t))"
     R="0.05*(1.0*(0.5+0.5*sin(2*PI*0.05*t+0.9))*sin(2*PI*98.6*t) + 0.7*(0.5+0.5*sin(2*PI*0.061*t+1.9))*sin(2*PI*196.6*t) + 0.35*(0.5+0.5*sin(2*PI*0.037*t+0.9))*sin(2*PI*147.6*t) + 0.3*(0.5+0.5*sin(2*PI*0.053*t+2.9))*sin(2*PI*220.6*t) + 0.28*(0.5+0.5*sin(2*PI*0.041*t+4.9))*sin(2*PI*262.6*t) + 0.24*(0.5+0.5*sin(2*PI*0.067*t+1.9))*sin(2*PI*294.6*t) + 0.2*(0.5+0.5*sin(2*PI*0.047*t+3.9))*sin(2*PI*330.6*t) + 0.14*(0.5+0.5*sin(2*PI*0.029*t+5.9))*sin(2*PI*393.2*t))" ;;
  1) name="nebula"; lp=2400; rev="aecho=0.8:0.9:130|210|300:0.28|0.2|0.13"
     L="0.05*(0.9*(0.5+0.5*sin(2*PI*0.046*t+0.0))*sin(2*PI*110.0*t) + 0.6*(0.5+0.5*sin(2*PI*0.058*t+1.0))*sin(2*PI*165.0*t) + 0.34*(0.5+0.5*sin(2*PI*0.039*t+2.0))*sin(2*PI*220.0*t) + 0.28*(0.5+0.5*sin(2*PI*0.052*t+3.0))*sin(2*PI*277.0*t) + 0.24*(0.5+0.5*sin(2*PI*0.044*t+0.0))*sin(2*PI*330.0*t) + 0.14*(0.5+0.5*sin(2*PI*0.071*t+4.0))*sin(2*PI*440.0*t) + 0.1*(0.5+0.5*sin(2*PI*0.089*t+1.0))*sin(2*PI*554.0*t) + 0.07*(0.5+0.5*sin(2*PI*0.101*t+5.0))*sin(2*PI*659.0*t))"
     R="0.05*(0.9*(0.5+0.5*sin(2*PI*0.046*t+0.9))*sin(2*PI*110.6*t) + 0.6*(0.5+0.5*sin(2*PI*0.058*t+1.9))*sin(2*PI*165.6*t) + 0.34*(0.5+0.5*sin(2*PI*0.039*t+2.9))*sin(2*PI*220.6*t) + 0.28*(0.5+0.5*sin(2*PI*0.052*t+3.9))*sin(2*PI*277.6*t) + 0.24*(0.5+0.5*sin(2*PI*0.044*t+0.9))*sin(2*PI*330.6*t) + 0.14*(0.5+0.5*sin(2*PI*0.071*t+4.9))*sin(2*PI*441.2*t) + 0.1*(0.5+0.5*sin(2*PI*0.089*t+1.9))*sin(2*PI*555.2*t) + 0.07*(0.5+0.5*sin(2*PI*0.101*t+5.9))*sin(2*PI*660.8*t))" ;;
  2) name="umbra"; lp=1100; rev="aecho=0.85:0.9:150|260|380:0.3|0.22|0.15"
     L="0.05*(1.0*(0.5+0.5*sin(2*PI*0.033*t+0.0))*sin(2*PI*73.4*t) + 0.6*(0.5+0.5*sin(2*PI*0.041*t+1.0))*sin(2*PI*110.0*t) + 0.32*(0.5+0.5*sin(2*PI*0.027*t+0.0))*sin(2*PI*146.8*t) + 0.3*(0.5+0.5*sin(2*PI*0.049*t+2.0))*sin(2*PI*174.6*t) + 0.22*(0.5+0.5*sin(2*PI*0.037*t+4.0))*sin(2*PI*220.0*t) + 0.16*(0.5+0.5*sin(2*PI*0.043*t+1.0))*sin(2*PI*261.6*t) + 0.1*(0.5+0.5*sin(2*PI*0.031*t+3.0))*sin(2*PI*349.0*t))"
     R="0.05*(1.0*(0.5+0.5*sin(2*PI*0.033*t+0.9))*sin(2*PI*74.0*t) + 0.6*(0.5+0.5*sin(2*PI*0.041*t+1.9))*sin(2*PI*110.6*t) + 0.32*(0.5+0.5*sin(2*PI*0.027*t+0.9))*sin(2*PI*147.4*t) + 0.3*(0.5+0.5*sin(2*PI*0.049*t+2.9))*sin(2*PI*175.2*t) + 0.22*(0.5+0.5*sin(2*PI*0.037*t+4.9))*sin(2*PI*220.6*t) + 0.16*(0.5+0.5*sin(2*PI*0.043*t+1.9))*sin(2*PI*262.20000000000005*t) + 0.1*(0.5+0.5*sin(2*PI*0.031*t+3.9))*sin(2*PI*350.2*t))" ;;
  3) name="crystal"; lp=3000; rev="aecho=0.75:0.85:170|300|470:0.32|0.24|0.16"
     L="0.05*(0.8*(0.5+0.5*sin(2*PI*0.044*t+0.0))*sin(2*PI*87.3*t) + 0.4*(0.5+0.5*sin(2*PI*0.056*t+1.0))*sin(2*PI*174.6*t) + 0.2*(0.5+0.5*sin(2*PI*0.061*t+0.0))*sin(2*PI*261.6*t) + 0.13*(0.5+0.5*sin(2*PI*0.077*t+2.0))*sin(2*PI*393.0*t) + 0.11*(0.5+0.5*sin(2*PI*0.091*t+4.0))*sin(2*PI*523.0*t) + 0.09*(0.5+0.5*sin(2*PI*0.067*t+1.0))*sin(2*PI*626.0*t) + 0.07*(0.5+0.5*sin(2*PI*0.103*t+3.0))*sin(2*PI*784.0*t) + 0.05*(0.5+0.5*sin(2*PI*0.083*t+5.0))*sin(2*PI*933.0*t))"
     R="0.05*(0.8*(0.5+0.5*sin(2*PI*0.044*t+0.9))*sin(2*PI*87.89999999999999*t) + 0.4*(0.5+0.5*sin(2*PI*0.056*t+1.9))*sin(2*PI*175.2*t) + 0.2*(0.5+0.5*sin(2*PI*0.061*t+0.9))*sin(2*PI*262.20000000000005*t) + 0.13*(0.5+0.5*sin(2*PI*0.077*t+2.9))*sin(2*PI*394.2*t) + 0.11*(0.5+0.5*sin(2*PI*0.091*t+4.9))*sin(2*PI*524.2*t) + 0.09*(0.5+0.5*sin(2*PI*0.067*t+1.9))*sin(2*PI*627.8*t) + 0.07*(0.5+0.5*sin(2*PI*0.103*t+3.9))*sin(2*PI*785.8*t) + 0.05*(0.5+0.5*sin(2*PI*0.083*t+5.9))*sin(2*PI*935.4*t))" ;;
  *) name="aurora" ;;
esac

stream="computer-thinking-tone"
ffmpeg -hide_banner -loglevel error -nostdin \
  -f lavfi -i "aevalsrc=exprs=$L|$R:s=48000" \
  -af "lowpass=f=$lp,$rev,volume=$vol,afade=t=in:d=0.9" \
  -f pulse -stream_name "$stream" default &
ff=$!

# Our sink-input index: the newest stream (nothing else plays, per the check).
sid=""
for _ in 1 2 3 4 5 6 7 8; do
  sid=$(pactl list short sink-inputs 2>/dev/null | tail -1 | cut -f1)
  [ -n "$sid" ] && break
  sleep 0.1
done
# Force full stream volume. PipeWire's stream-restore remembers per-app volume,
# and our fade-out (ramp to 0 then stop) would otherwise be recalled as 0% and
# silence the next run. Level is set entirely by ffmpeg's volume filter, so the
# stream itself always plays at unity.
[ -n "$sid" ] && pactl set-sink-input-volume "$sid" 100% 2>/dev/null

on_stop() {
  # Quick fade-out (~0.35s) by ramping the stream volume, then stop.
  if [ -n "$sid" ]; then
    for v in 78 55 36 20 8 0; do pactl set-sink-input-volume "$sid" "${v}%" 2>/dev/null; sleep 0.06; done
  fi
  kill "$ff" 2>/dev/null
  wait "$ff" 2>/dev/null
  exit 0
}
trap on_stop TERM INT
wait "$ff"
