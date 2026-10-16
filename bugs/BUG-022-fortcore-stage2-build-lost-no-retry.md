# BUG-022 fortcore stage 2 ends `build_lost` for good: the inner bridge B1 and the traps are never built, R0 stays red
Status: fixed (offline, live-untested); the runner now does the workaround itself
Severity: high for defense (the only entrance has the outer gate and no inner gate/traps)
Found: 2026-10-15 21:15, Run 10 fort Handlelock (region2-site97, y364-366), dfpilot main 95fe16d
Module: `lua/dfllm/runner.lua` (apply stages, `lost_pct`, `set_blocked(.., 'build_lost')`), template `fortcore`

## Actual
```
y364s2b0 s2.dig chunk 0: quickfort skipped 0 off map, 5 invalid, 0 engraved
y364s2b0 s2.dig chunk 1: quickfort skipped 0 off map, 12 invalid, 0 engraved
y364s2b0 s2.dig: 61 hidden tiles never reached; stage completes without them
y364s2b0 s2.build: 6 manager orders, 15 items
inspect projects: y364s2b0 fortcore stage 1 pct 25 blocked build_lost chunk 1 done 0   (for two game years; PROJECT_BLOCKED stalled every few days)
status:  R0 fail: audit, bridge:B1, levers:B1    traps 0
```
Stage 3 (`y364s3b0`) finished 100 %, stage 1 100 %; `inspect defense`: `B2 down/open, O1 down/open, B1 missing`. The runner re-applies a stage once (`R.ra`) and then blocks when more than `lost_pct` of the
buildings are lost; nothing retries, replans or tells which tiles were invalid.

## Expected
A stage whose dig skipped hidden/invalid tiles is rebuilt on the tiles that exist, or the project says which pieces are missing (`B1`, traps) and a follow-up project is queued; PROJECT_BLOCKED does not repeat for ever.

## Fix proposal
Persist the list of invalid/unreached tiles per chunk and offer `bp.place fortcore stage=2 retry=1` that places only the buildings with tiles that are now dug; raise one `SIEGE_UNREADY` (FR-65) naming B1 and the missing traps.

Related: FR-65, BUG-018, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`

## Workaround (live, 2026-10-15 23:10 / Run 10 y372)
`cmd bp.cancel proj=y364s2b0`, then a plan for the current year with only `{"tpl":"fortcore","site":"same","p":{"stage":2}}` in s0 (`plan propose` / edit / `check` / `apply`; `same` reuses the anchor of the fort): the new project `y372s0b0` ran stage 2 to the end
(`s2.dig: 5 + 12 tiles never designated, skipped`, `s2.build: 6 manager orders, 15 items`), B1 (128,127,122) and its 3 levers stand (`inspect defense`: `B1 down/open 3lev`), R0 now only `audit`.
The first try failed because the tiles of the Z3 gatehouse had not been reached yet; stages 3 and 4 and two game years later they were. So the dig skip is not permanent; the runner could retry the stage instead of blocking `build_lost`.

## Fix (Claude, 2026-10-16)
`lua/dfllm/runner.lua` does what the live workaround did by hand:
- **Skipped tiles are kept.** A dig stage that completes without hidden tiles (quickfort could not designate them, e.g. smoothing on
  unrevealed rock, or the miners never reached them: `61 hidden tiles never reached`) records them per chunk in persist `m.runner`
  `skip[<proj>] = {si, n, c = {["<chunk>"] = [[x,y,z], ...]}}` (at most 200; only tiles that were hidden; revealed tiles skipped for other
  reasons, soil or the map edge, are not kept).
- **build_lost is retried.** For a project blocked `build_lost` the runner compares, once a game day in PEACE, how many of the kept tiles
  snapshot.tile now answers as revealed plus how many missing cells of the blocked stage stand on open floor with the number at the
  block. When it grew, or at the latest one game season after the block, the project starts again at the last dig stage before the
  blocked stage (P.stage, chunk, orders reset; `y364s2b0: build_lost at s2.build, retry 1/8 from s2.dig (7 more tiles revealed or
  open)`). The dig designates what is reachable now, the build stage places only what is missing (existing buildings are tracked, the
  orders skip occupied cells, as in live L2), and the project finishes or blocks again. At most 8 retries (`m.runner rty`).
  Only revealed tiles are read (snapshot.tile answers nil for hidden ones); nothing else changes the map.
- **PROJECT_BLOCKED** follows the cadence rule per project: once per stage and cause (a stall that clears and comes back at the same stage
  is no news; the old code announced every new stall episode), and a spent retry budget once more. For `build_lost` it names the missing
  pieces from the stage's cells without a building (manifest bridge footprints and their levers by name, traps as `trap`, other keys as
  the key): `y364s2b0 (fortcore) blocked: build_lost at s2.build, missing B1, lever B1 x3, trap; retry 1/8 once the skipped tiles are
  revealed, at the latest next season`; d `missing`, `retry`. After the last retry: `...; 8 retries spent: bp.cancel and place it again`.
- Not done: SIEGE_UNREADY (FR-65) naming B1 and the missing traps belongs to readiness (another branch); the PROJECT_BLOCKED text and
  `d.missing` carry the same names for it.
- Tests (`tests/lua/test_runner.lua`, all three fail on the old code): a fortcore-like stage 2 whose dig leaves 4 hidden tiles and whose
  build loses B1 and a trap: kept tiles, one PROJECT_BLOCKED with `missing B1, trap`, no retry while nothing changes, the retry from
  `s2.dig` once the tiles are revealed, then the project finishes; without news: retries every `retry_every`, `retry_max` times, then one
  final PROJECT_BLOCKED; a stall that comes back at the same stage is announced once.
- Live check: on a fort with a `build_lost` project watch kern.log for `retry n/8 from ...` after the gatehouse tiles are reached, and
  `inspect defense` for B1; PROJECT_BLOCKED must name the missing pieces and come once per stage.
