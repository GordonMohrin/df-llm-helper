# BUG-074 The temporary gather zone covers a square around the fort, walls and cut-off meadows included: 46 of its jobs were unreachable
Status: fixed in 954ddb1 (offline, live-untested): the zone is cut to the tiles of the walk group most citizens stand on
(rectangles, at most `gather_rects` 60 a level), the log names the tiles left out; a zone of an older kernel is removed
once and drawn again; the walk group unknown: the whole square as before
Severity: medium (jobs nobody can do: the gatherers' lists fill with unreachable GatherPlants, 46 flagged unreachable,
250-450 unclaimed for years)
Found: 2026-10-17..23, Run 11 fort Kilrudrabed (site98), y479; decided 2026-10-23 (DECISIONS 10)
Module: `lua/dfllm/runner.lua` (`gather_zone`, `Q.home_group`, `Q.gather_rects`), `lua/dfllm/snapshot.lua` (`groups`)

## Actual (live, game session)
The `dfllm-gather` zone (28 x 28 around the fortcore anchor, one or two levels) held GatherPlants designations on tiles
the citizens' walk group does not reach (outside the walls, behind the raised bridges); 46 of them were flagged
unreachable. Package B1 withdraws designations nobody works for N days; this fixes the geometry.

## Cause (runner.lua at f17e2b3, `gather_zone`)
1. The zone is one quickfort cell `g{name=dfllm-gather}(SxS)` on the square around `fort_center` (the fortcore anchor):
   the whole square, with no look at the walk group of its tiles.
2. The level choice counted `OPEN` tiles (`.` and `T`) of a sampled grid whatever their group, so a level whose open tiles
   lay outside the walls could win.

## Fix
- `Q.home_group(K)`: the group most citizens stand on (census ids -> positions -> `snapshot.groups`, near false; at most
  50 citizens; ties the lower id). nil when no citizen is read or no group is positive.
- Level choice: the sampled open tiles count only when `snapshot.groups(..., near)` puts them on that group.
- `Q.gather_rects(K, g, x0, y0, side, z, cap)`: one `snapshot.groups` call for the square (near: a tree trunk takes its
  neighbours' group), row runs on the group, equal runs of consecutive rows joined into rectangles, the `cap` largest kept
  (config `runner.CFG.gather_rects` 60, a sibling of `gather_cap`/`gather_side`). One quickfort zone call per level with a
  cell per rectangle (`g{name=dfllm-gather}(WxH)` at its offset).
- The log: `food 20 days: gather zone at 86,86 on z 62: 616 tiles in 1 rects on the citizens' walk group 7, 168 tiles of
  the 28x28 square left out (not on that group, or past the 60-rect cap)`; the record `m.runner gather` gets `v 2`, `g`,
  `n` (tiles drawn), `out` (left out). No reachable open tile: no zone, `gather zone: no revealed open tile on the
  citizens' walk group around x,y,z`, no retry until food recovers (as for a level without open tiles).
- Walk group unknown or its read failed: the whole square and the old log line, so a fault never leaves the fort without
  a zone. A zone an older kernel drew (record without `v`) is removed once (`zone_remove`) and drawn again while food is
  below `gather_below` in spring to autumn and the home group is known.
- Safety: a smaller zone only removes jobs nobody could do; the zone is still never larger than before, still removed
  above `gather_off`; a fort of 7 (few citizens) reads their group the same way; in SIEGE/BREACH the keepers do not run
  (`K.mode() ~= 'PEACE'`), nothing changes there.

## Not decided offline
Whether quickfort merges the rectangles of one blueprint into fewer activity zones (each cell may be one zone): the live
count is `#df.global.world.buildings.other.ACTIVITY_ZONE` entries named `dfllm-gather` after a draw (`zone_remove` returns
the number it removed, kern.log `gather zone removed (food N days, K zones)`). The 60-rect cap bounds it either way.

## Tests
`tests/lua/test_runner_c4.lua` (fail on f17e2b3): a wall line splits the square (group 7 west, 9 east): one 22x28 cell,
616 tiles, 168 left out, log text, record; a cut-off pond gives rectangles around it and the cap keeps the largest;
no citizen read: the old whole-square cell and log; nothing on the group: no zone and a log line; an older kernel's zone
is removed once and redrawn.
