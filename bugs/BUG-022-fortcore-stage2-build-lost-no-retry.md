# BUG-022 fortcore stage 2 ends `build_lost` for good: the inner bridge B1 and the traps are never built, R0 stays red
Status: open (workaround works: cancel the project and re-plan stage 2, see the end of this file)
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
