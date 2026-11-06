# BUG-517 PERIMETER OPEN for a sealed wall, and a wall in front of a lever-less bridge does not close it
Status: fixed (offline, live-untested)
Severity: high (open_perimeter held the population ceiling for years; R0 and the wake repeated)
Found: 2026-11-06, Run 16b i2 Roadvises y381/y383/y384 and Run 16d i4 Trumpetrealms y383-y393 (`runs/run-16b/FR-BUGS.md` 'status zeigt PERIMETER OPEN fuer bereits gesealte Wand', `runs/run-16d/FR-BUGS.md` 'Wand vor O1 gebaut (84,72,139), PERIMETER OPEN bleibt')
Module: `lua/dfllm/seal.lua` (`due`, `BFS_WHY`, `M.on['EV:PROJECT_DONE']`, `opening_doors`, `M.bridge_way`), `lua/dfllm/readiness.lua` (`open_perimeter`)

## Actual
1. status `1 way in without door or bridge: 85,77,138 wall` / `PERIMETER OPEN 11-16 d` beside a finished seal wall or door; only `inspect entrances key=refresh` showed the truth (1 door, 0 openings).
2. A wall at 84,72,139 in front of O1 (whose levers were not linked) left `PERIMETER OPEN 3279 days: levers lost: O1`; `open_perimeter` ignored what stood in front of the bridge.

## Root cause
1. `seal.lua` `watch`: a construction change asks for an entrance check only `at once while sealed, else daily` (`mem.seal_ct`); in PEACE the BFS re-uses its answer (`seal_pass` `need`) unless a known opening closed or `bfs_every` (28 days) passed. The last construction of a seal, inside the day of the first one, asked for nothing, so `entrance_doors` (the one source of status, SIEGE_UNREADY and `seal at=last`) stayed old.
2. `readiness.lua` `open_perimeter`: `levers:<bridge>` (fewer than 2 linked levers, bridge once seen whole) counted as 'levers lost' whatever lay in front of the bridge.

## Fix
- `seal.lua`: PROJECT_DONE of a seal project queues a fresh entrance check (`due('seal', t, 'sealdone')`, a BFS reason that beats a queued 'construction').
- `opening_doors` returns the bridge tiles each opening's route crosses before any door (`res.openings[i].br`). New `seal.bridge_way(fp)`: true when an opening runs over the bridge, false when none does or the fort is sealed, nil when not proven (no check, partial, openings left out).
- `readiness.open_perimeter`: `levers lost: X` is dropped when `seal.bridge_way(fp of X)` is false (a wall or door stands in front, or the fort is sealed); unproven keeps it. Lost bridges and open ways in are unchanged. gate.lua is untouched.

## Tests
`tests/lua/test_bug517_perimeter_fresh.lua` (4: bridge_way nil / true, constructions inside a day lag and PROJECT_DONE of a seal refreshes (bridge_way false, only the plain gap left open), a hospital does not force a check, readiness drops 'levers lost' for false and keeps it for true / nil).

## Live check
After a seal project is done: `inspect entrances` and status agree within minutes; a wall in front of a lever-less bridge: `PERIMETER OPEN` ends at the next daily readiness run (R0 `levers:O1` stays as the lever blocker). Open: `levers:O1` itself (the retrofit that does not link the refuge levers) is not changed.
