#!/bin/bash
# scan2.sh : run probe.sh over a grid of embark positions and collect the panels in $OUT (default ./scan2.out).
# EXPERIMENTAL. Adjust the x/y ranges to the embark map (embx = 16*world_x + local_x). Never run probes back-to-back
# without the sleeps inside probe.sh (fast double clicks crashed DF once).
EMBARK_DIR="${EMBARK_DIR:-$(cd "$(dirname "$0")" && pwd)}"
OUT="${OUT:-./scan2.out}"
rm -f "$OUT"
for y in 160 168 176 184 192 200; do for x in 400 408 416 424 432 440; do
  out=$("$EMBARK_DIR/probe.sh" "$x" "$y" 2>/dev/null | tr '\n' '|')
  echo "$x,$y :: $out" >> "$OUT"
done; done
echo DONE >> "$OUT"
