# BUG-758 A lone wild animal raises the outer bridge in ALERT and a soldier on his way to his station is crushed by it
Status: fixed (offline, live-untested)
Severity: high (a soldier died on O1; any unit that walks onto a raised-for-nothing bridge dies)
Found: 2026-11-11, Run 16b i2 Whirledrampart y441 (`E:/DF-test2/dfllm-runtime/r16b7-whirledrampart-site98/` events #15415-#15429, kern.1.log, commands.log, read only): ALERT_START for ONE Megalania 31106 (7,609 cm3, 'inside the fort') at tick 178212459; `gate: O1 up waits ...` (7 units) at 178212648, pull of lever 19399 queued 178212998 (act.pull), taken 178213136 (O1 moving), GATE_CRUSH_RISK 178213228 'soldier 29764 on the footprint at 85,131,140', BRIDGE_CRUSH + DEATH 178213236 (O1 up 238 ticks after the queueing). Squad 102 had been ordered to a station at 116,132,140 at the ALERT start (commands.log act.squad_order) and marched across O1.
Module: `lua/dfllm/siege.lua` (`apply`, ALERT branch), `lua/dfllm/gate.lua` (`holders`, `M.raise_movers`)

## Actual
One wild animal inside the fort (no invader, no great danger) made the ALERT want O1 up; the raise was pulled although soldiers were marching over it, the bridge moved for ~100 ticks and one of them stepped onto the footprint.

## Root cause
1. `siege.lua` `apply` (mode ALERT): any hostile within `ALERT_O1` (30) tiles of O1 (`a.near_o1`) wanted every outer bridge up, a lone wild animal included. It was already inside; a raised O1 shuts nothing out and only endangers the people on the route between the barracks and the stations.
2. `gate.lua` `holders` (`dir == 'up'`, not SIEGE/BREACH): BUG-587 skipped `M.raise_movers` altogether (BUG-543: units that are not standing still within `RAISE_R` tiles hold a non-emergency raise) when a hostile was within `approach_near` (30) tiles of the footprint. The marching soldiers have no readable path (they are not in `M.crossers`), so nothing held the pull; the in-flight window after the lever is pulled (~100 ticks) is only covered by that mover hold.

## Fix
- `siege.apply` ALERT: the outer bridges are wanted up only when the visible hostiles include an invader, a great danger, an undead or a building destroyer (`a.inv + a.great + a.undead + a.bd > 0`); a lone wild animal raises nothing (soldiers kill it; BREACH handles one inside Kern+).
- `gate.holders` / `M.raise_movers(K, name, sc, hold, soldiers)`: with a hostile within approach range the movers rule still holds for SOLDIERS (moving within `RAISE_R` tiles, not standing still); only the citizens' recall stream (BUG-587) is let go. SIEGE/BREACH rules (forced raise only past people beside the footprint, never onto one ON it) are unchanged.

## Open
A unit that is farther than `RAISE_R` tiles and has no readable path when the lever is pulled, and walks onto the footprint inside the ~100 ticks the bridge moves, is still not held (nothing can stop a moving bridge; GATE_CRUSH_RISK / BRIDGE_CRUSH report it). An ALERT with an invader far from O1 and a wild animal near it still raises O1 (`a.near_o1` takes the nearest hostile of any kind).

## Tests
`tests/lua/test_bug758_alert_predator_crush.lua` (5, the siege traffic test included): a lone wild animal within 30 tiles of O1 raises nothing (a soldier pacing beside it is not crushed); an invader there with a soldier pacing 3 tiles from O1 who steps on the tick the bridge moves: held while he paces, raised once he stands, nobody crushed; a pacing citizen does not hold it (BUG-587); SIEGE with closing invaders and a stream of citizens and soldiers over O1, B1, B2 plus a pacing soldier: nobody crushed, O1 and B1 up before T+900, walkers of the stream stand inside; a soldier standing ON O1 during a predator alert is never crushed. The siege traffic tests of BUG-543, 587 and 577 pass unchanged.

## Live check
No `GATE_CRUSH_RISK` / `BRIDGE_CRUSH` of a soldier in ALERT; no `LEVER pull O1 up` while the only hostile is a wild animal.
