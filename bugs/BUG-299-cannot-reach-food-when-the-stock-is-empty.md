# BUG-299 'cannot reach food' when the food stock is simply empty
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/economy.lua` (cut_off, T.starve)

## Actual
Run 15c Inkintense y376: DECISION_NEEDED starvation `28 hungry, food 0 days, 28 cannot reach food` (#1361, also #1096, #1334, #1490) while `inspect reach` put all 50 citizens and all 176 food items on one walk group. Root cause: economy.lua cut_off counted every hungry citizen as cut off when the census had no reachable food sample (`#samples == 0 -> reach = false`), i.e. when no edible food lay free at all.

## Fix
No food sample = nobody is cut off; the starvation line says `no food left` and the question `no food left to eat (the stock is empty, not cut off)`; kern.log `no food left (the stock is empty)`. A real cut (food lies free, a citizen cannot reach it) is named as before.

## Tests
`tests/lua/test_fix10_economy.lua` (BUG-299). Fail on 05dc764.

## Live check
at the next starvation with 0 food days: DECISION_NEEDED `starvation: N hungry, food 0 days, no food left`; with food in a cut-off room the names come as before.
