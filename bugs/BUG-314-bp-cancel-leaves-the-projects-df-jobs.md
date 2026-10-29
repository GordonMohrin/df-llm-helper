# BUG-314 bp.cancel leaves the project's planned buildings and their DF jobs
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15 Earthboat (FR-BUGS y382) and Drillchamber (y377)
Module: `lua/dfllm/runner.lua` (cancel, Q.unbuilt_cells, Q.remove_unbuilt, undo, verb bp.cancel)

## Actual
Earthboat y382: `cmd bp.cancel proj=y373s1b0` (ok), `bp.place tpl=seal site=S1 at=refuge` -> c1a1884b90c4405401; SEAL_STUCK #5305
`hatch 55,82,133: job 8095 not suspended, no builder has taken it` - the job of y373. Drillchamber y377: y377s0b0 inherited job
10421 of the cancelled y374s0b0. commands.log shows no quickfort undo at the cancel, only the new `run` (154048084).

## Root cause
runner.lua cancel (line 2736 on 9ef2ccb): a plain cancel (undo false) only removed the project record (`remove`); the hatch
building and its ConstructBuilding job stayed in DF. The next seal's build chunk found the tile occupied, adopted the old
building (pre_occupied, runner.lua:1396) and waited on the same job.

## Fix
A plain `bp.cancel` collects the cells of the current build stage whose building the project placed or adopted (R.b, R.c) and is
not built (Q.unbuilt_cells), marks the project `cancel` and removes them one quickfort undo each (the player's remove building on
a planned one; its job goes with it) in the undo task, a piece built meanwhile stays; then the project is removed. The verb answers
`cancelling <id> (N unbuilt piece(s) removed first, their jobs with them)`; kern.log `... cancelled: N unbuilt piece(s) removed`.
Built pieces and buildings the project does not own are never touched; `undo=true` is unchanged.

## Tests
`tests/lua/test_fix11_builders.lua` `BUG-314 ...` (fails on 9ef2ccb).

## Live check
`dfllm cmd bp.cancel proj=<a seal with an unbuilt hatch>`: the answer names 1 unbuilt piece, commands.log `act.quickfort undo` at
the hatch tile, the hatch gone in the game; a new `seal at=refuge` then names a new job id in SEAL_STUCK/inspect projects.
