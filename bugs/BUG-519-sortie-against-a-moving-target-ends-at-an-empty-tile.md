# BUG-519 squad.sortie against a goblin snatcher is useless: the squad reaches the reported tile and nobody is there
Status: fixed (offline, live-untested)
Severity: medium (the one answer the kernel offers to a lone intruder fails; the lockdown runs on)
Found: 2026-11-06, Run 16a i1 Basementflew y403/y404 (`runs/run-16a/FR-BUGS.md` "OBS INVASION y403/y404: derselbe Goblin-Snatcher (inv 24878) zweimal, Sortie 'no visible hostile within 5 tiles'"; read only). Earlier: BUG-113 (the position sortie)
Module: `lua/dfllm/military.lua` (`M.verbs['squad.sortie']`, `sortie_pass`), `lua/dfllm/reflex.lua` / `sense.lua` / `siege.lua` (the offered command), `dfpilot/schema.py`, `lua/dfllm/siege.lua` (`M.SO`)

## Actual
INTRUDER (and PREDATOR, WATER_PREDATOR, intruder_sortie, kill_lone_intruder, siege_long) offer `squad.sortie {"squad","target":[x,y,z],"approve":true}`. The target is the tile where the unit was seen. A snatcher walks on: when the command is sent the verb found "no visible hostile within 5 tiles" and gave the squad a plain move order; 1,212 ticks later the squad stood on the empty tile and the sortie ended `nobody within 5 tiles to attack`; SIEGE_END `3 hostiles, 0 killed`.

## Root cause
`military.lua squad.sortie` (position branch) turned a position without a hostile within `sortie.kill_near` (5) into `{kind = 'station'}`, and the arrival test (`sortie_pass`, kind station) ended `no_target` with the same 5-tile test. Only a *kill* order follows its unit (by id, position from the census); the report never gave the id.

## Fix
- The offered commands carry `"unit":<id>` (sense, reflex x3, siege); the verb takes `unit` (kill order on that unit, position from the census now) and refuses a unit that is not in sight, naming it and the reported tile (`move=true` still moves the squad there).
- A position with nobody within 5 tiles takes the nearest visible hostile within `sortie.track_near` (new, default 25, config/reflex.json `sortie`, limit 0-100) as the target; with nobody in sight the verb is refused with the reason (`the target is gone`) instead of moving the squad to an empty place; `move=true` is the old plain move.
- A station sortie that arrives at an empty tile follows the nearest hostile within `track_near` (SORTIE go), else ends `no_target` and says whether a hostile was in sight at all.

## Tests
`tests/lua/test_bug519_sortie_track.lua` (4: `unit` follows, a gone unit is refused / `move=true`, empty tile takes the nearest or is refused, arrival retargets or ends naming the gone target); `test_m3_sortie.lua` and `test_military.lua` adapted (a position 9-20 tiles from the only hostile is a kill order now; the plain move needs `move=true`), `tests/test_bug518_522_f32.py` (schema, config limit).

## Live check
Next INTRUDER with a squad: the cmd line has `"unit":N`; `dfllm cmd squad.sortie` answers `kill order on N (follows the unit; now at x,y,z)`; SORTIE go names the unit. If the unit left the view the reply says so at once and the squad stays at its station.
Open: a unit that leaves the view while the squad walks is ended by the existing `gone` rule after `sortie.idle_ticks`.
