# BUG-600 The perimeter counts ways in the next check no longer lists, and lags a day behind a finished seal
Status: fixed (offline, live-untested)
Severity: medium (R0 `open_perimeter` and a lowered pop ceiling from tiles that vanish; a wall that stands is reported open for a day)
Found: 2026-11-09, Run 16a i1 Basementflew y413 (`perimeter OPEN` with floor / pebbles tiles 78,110,139; 83,129,139; 129,114,139 that were gone at the next check, `seal at=last` 'nothing to close'; the check lagged a day), Run 16b i2 Brotherarrow y405 / y412 (`perimeter OPEN 7 d (1 way in)` after `1,159,139: left out, sealed by ... (done; the entrance check may lag)`)
Module: `lua/dfllm/readiness.lua` (`entrances`, `M.on['EV:SEAL']`)

## Actual
BUG-566 left sapling and shrub tiles out of the perimeter; the tiles in the logs were `floor` and `pebbles`: a plant that grew or died (or a crown that fell) leaves a plain floor tile at the rim of the "inside" for one check. readiness counted every way of the last check at once (R0 `open_perimeter`, the pop hold, SIEGE_UNREADY), and after a finished seal it kept the old answer until its next daily evaluation.

## Root cause
1. `readiness.entrances` (readiness.lua, FR-65) took each way in without door or bridge of seal's last check as a way in, with no memory of the tile.
2. The fresh check that `seal` runs after a finished seal project (`sealdone`, BUG-517) lands after readiness' own PROJECT_DONE evaluation, and readiness did not look at the SEAL event seal emits for it: status and ceiling read the old answer until the next evaluation.

## Fix
- In PEACE a way in counts once the SAME tile has stayed in the answer for `OPEN_CONFIRM` (2400 ticks = two game days) in evaluations that saw it; a tile that is gone at a look is forgotten, a new tile each day never counts; a running open spell (`ready.pt`) and every other mode count at once. kern.log: `N ways in younger than 2400 ticks left out of the perimeter ...`.
- readiness evaluates at once on a SEAL event with `why` `sealdone` or a changed `routes` (`M.on['EV:SEAL']`): status, pop ceiling and SIEGE_UNREADY follow the fresh check within the minute.

## Tests
`tests/lua/test_bug600_601_perimeter_armor.lua` (3: a tile counts after two days, a new tile each day never; ALERT counts at once; SEAL `sealdone` reads the fresh answer); the older readiness / perimeter tests run with `OPEN_CONFIRM` 0 (`test_open_perimeter.lua`, `test_readiness.lua`, `test_bug478_481_defense_ready.lua`)

## Live check
`status` after a `seal at=last` finished: `ways in` falls within the minute; a fort with growing plants at the rim shows `readiness: N ways in younger than 2400 ticks left out` in kern.log and no `PERIMETER OPEN` from them; a real open door still shows after two game days (and at once in a siege).

## Open
A real new opening in PEACE is reported two game days later than before (the freeze waits `escalate_days` anyway); seal's BFS still re-runs only when a way's tile changed (BUG-566) or every `bfs_every` days. Why the floor / pebbles tiles appeared at the rim is inferred (plants), not read from the raws.
