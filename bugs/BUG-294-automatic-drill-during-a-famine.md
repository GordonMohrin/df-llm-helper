# BUG-294 automatic drills start during a famine
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/drill.lua` (M.supply_hold, check)

## Actual
Run 15c Inkintense y376: MODE PEACE>DRILL `auto: retry` at food 9 d (#1403) and again at food 1 d (#1488); each drill pulled everyone into Kern+, took the hunters off (BUG-295) and clamped the clock. Root cause: drill.lua check() refused only for danger, settling, bridges, soldiers and barracks; the supply alarm and the stock days were never asked.

## Fix
No automatic drill while economy.alarm() is set (thirst, hunger, drink or food days) or food or drink stands below SUPPLY_MIN 30 days; the hold reads `supply: food 9 d` (drill.hold, state ready.dhold, status `drill never (auto: ...)`). The player's `drill` stays his choice.

## Tests
`tests/lua/test_fix10_famine.lua` (BUG-294). Fail on 05dc764.

## Live check
in a fort below 30 food days: `dfllm status` shows `supply: food N d` as the drill hold and no MODE PEACE>DRILL `auto:` event until food is back.
