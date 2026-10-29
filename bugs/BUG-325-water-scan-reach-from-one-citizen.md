# BUG-325 the water scan asks the walk from one citizen: one in another walk group hides every bank and well spot
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15 round 3 (Earthboat y385, live kern.log)
Module: `lua/dfllm/water.lua` (new_scan, scan_body reachable, M.origins, M.reach_any)

## Actual
Earthboat, a few game days apart, the same scan area: `water sources: 1496 tiles >= 4/7 in 12 bodies, 1 with a bank or a dig, 12 with a well spot` (tick 155174116) and `1490 tiles >= 4/7 in 12 bodies, 0 with a bank or a dig, 0 with a well spot` (155302780); the last three scans all said 0. The river under its ramp tops did not change, so the well spots disappeared from the walk test, not from the map.

Root cause: `water.lua:862` (1d17c7e) took ONE walk origin, the citizen nearest the reference (the hospital, else the citizens' median), and `scan_body`'s `reachable` (water.lua:1020) asked `snapshot.reach` from him only. When that citizen stood in another walk group (inside the sealed refuge, a stranded woodcutter, a dwarf up a tree), every bank and well spot read unreachable, and BUG-324's zone (and the recipe) had nothing to offer.

## Fix
`M.origins(home, ref, ws_from)`: up to `ws_from` (3) citizens nearest the reference on distinct tiles; `M.reach_any`: a tile is reachable when any origin reaches it (an unreadable answer counts as reachable, as before); each tile still costs one of `ws_reach` checks. Config `water.ws_from` (1..10).

## Tests
`tests/lua/test_bug324_325_water_zone.lua` BUG-325 (fails on 1d17c7e): unit 1 next to the hospital in a walk group of his own, three others reach the river: the well spot is found; origins are distinct tiles.

## Live check
Earthboat: consecutive kern.log `water sources:` lines keep their `with a well spot` count while the river stands; `inspect water_sources` bodies keep `pit`/`stand`. Uncertain: that the live flip came from the origin (the most likely reading of identical tiles with different results; the origin's walk group was not logged).
