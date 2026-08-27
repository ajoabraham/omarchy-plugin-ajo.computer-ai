#!/usr/bin/env bash
# Summon the Computer panel listening, then focus its window so Enter/Esc
# work immediately (the compositor doesn't focus it on map by itself).
omarchy-shell shell summon ajo.computer-ai '{"listen": true}'
for _ in 1 2 3 4 5 6 7 8; do
  hyprctl dispatch 'hl.dsp.focus({ window = "title:^(Computer)$" })' >/dev/null 2>&1
  [ "$(hyprctl activewindow -j 2>/dev/null | jq -r .title)" = "Computer" ] && exit 0
  sleep 0.15
done
exit 0
