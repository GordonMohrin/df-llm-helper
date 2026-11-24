# BUG-832 return window ended before B1 was down, the raise was queued the tick the bridge settled (up/down churn)
Status: fixed (offline, live-untested)
Severity: high (the churn is what put citizens on the footprint)
Found: 2026-11-24, Run 17d i4 Girderroots y374: `GATE B1 opens for 600 ticks: 9 civilians outside it in PEACE (return window)` 151489814, `B1 down` 151490447 (633 ticks later), `LEVER pull B1 up` in the same tick; 45 raises and 363 LEVER events in the log; pulls repeated every ~1000 ticks (151003599 ... 151009734) while stragglers walked over the footprint
Module: `lua/dfllm/gate.lua` (`return_window`, `peace_want`)

## Actual
The return window of D-14 `inner` was counted from the moment it opened (`now + return_open`), but the lowering takes the lever latency (330-540 ticks) before the bridge is even down: the window was over when B1 reached `down`, the citizens it was opened for had not crossed, and the raise was queued at once. The same hold-then-pull cycle repeated for every short window.

## Fix
The window lasts `return_open` ticks after the measured lever latency (`now + return_open + lat`); the following raise needs the whole quiet window of BUG-831 (no unit within `peace_clear_r` for the latency window), so stragglers still walking in keep it down; a risk locks it (BUG-831).

## Tests
`tests/lua/test_bug831_833_peace_bridge.lua` (quiet window), `tests/lua/test_neu1_tore.lua` (return window).

## Live-Erwartung
1. `GATE B1 down` to the next `LEVER pull B1 up` in PEACE is at least `return_open` (600) plus the quiet window apart; no pull in the tick B1 settles down.
2. LEVER events per game day for B1 in PEACE fall (no pull every ~1000 ticks).
