# BUG-157 `bp sites` anchors hospital, tombs and workshops on the civilians' stair column, tombs at the refuge's hatch tile
Status: fixed (offline, live-untested)
Severity: medium (a room whose door opens off the citizens' main stair; tombs at the stair head the seal must close)
Found: 2026-10-28, live test i4 (new bug 5): `bp sites hospital` S1 [77,68,126] `0 steps to a stair`, tombs S1/S2 [77,68,127], `plan check` placed
tombs at [77,68,125] (the hatch tile), the Quern project anchored at [77,68,125]. The verifier judged the 0-step preference intended; the work
order for this package kept the exclusion in scope.
Module: `dfpilot/bp/sites.py` (`civ_stair_tiles`, `_anchor_tiles`)

## Actual
Room anchors were every public Z4 floor or up/down stair tile (`.X`); the ranking favours 0 steps to a stair, so every room of the fort fixture
was anchored on the civilian stair column (50,65 at every level).

## Fix
`civ_stair_tiles(manifest)`: every tile of the manifest's `stairs.civ` columns (the refuge hatch tile, above the refuge level, is one of them).
`_anchor_tiles` leaves them out for every room, the refuge-level rooms included. The rooms now open one step from the stair.

## Tests
`tests/bp/test_bp_sites_civ_stair.py` (hospital, tombs, workshops, dining, bedrooms, office; the best hospital is 1 step from the stair; the
refuge-level rooms): fail on main 2c0ffa3. `tests/bp/test_bp_sites_near.py`: `at=` on the stair tile is no valid anchor.

## Live check
`dfllm bp sites hospital --fresh` and `bp sites tombs`: no anchor on 77,68; `plan check` with tombs: never at 77,68,125.

## Not built
Ranking sites with many unknown tiles lower than now (`unknown // 10`); the hospital dig at i4 stopped on lost designations among 78 unknown tiles.
