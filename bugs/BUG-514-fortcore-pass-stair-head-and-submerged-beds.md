# BUG-514 fortcore below a passed aquifer: the stair head never dug, beds on water
Status: fixed (offline, live-untested)
Severity: high (the refuge hung in the air for 400 days, the core stage at 35 %)
Found: 2026-11-06, Run 16a i1 Basementflew y403-y405 (`runs/run-16a/FR-BUGS.md` 'fortcore (aquifer=pass) st1/st3 zerlegt')
Module: `dfpilot/bp/fortcore.py` (`_stage3`), `lua/dfllm/runner.lua` (`Q.wet_cells`, `apply`)

## Actual
`bp.place tpl=fortcore aquifer=pass` (S1 76,101,131, core z117, refuge z114) ran in pieces: stage 1 dug to z117 and its beds (34,92,117) were cancelled by DF 'Building site submerged' (damp rock, the dug level turned out to be an aquifer level); stage 1 was cancelled after the stale warning. The plan then drew stage 3 (`y404s0b2`): it dug the refuge room (28-34,97-105 z114) and the stair foot, but the stair between the levels belonged to stage 1 (`d.stair(*CIV, zr, ZE)`), so the manifest's stair head 31,101,115 was never dug ('refuge: no stair found (not dug) at the manifest's stair head'), the refuge could not be reached, and the next dig ran into `breach:water`.

## Root cause
`dfpilot/bp/fortcore.py` `_stage3`: the civilians' stair is dug only by `_stage1` (`d.stair(*CIV, zr, ZE)`); stage 3 dug `d.rect(-4, 42, 4, 48, zr)` and `.tile(*CIV, zr, "u")` and relied on stage 1. The runner has no check of the tile's water before it queues a bed (`runner.apply`).

## Fix
- `_stage3`: `d.stair(*CIV, zr, ZE)` first, then the room: stage 3 is whole on its own (tiles dug already are done for the runner's probe, the final cell at zr is still `u`).
- `runner.Q.wet_cells` (called in `apply` for a build chunk): a bed (`Q.WET_KEYS`) on a tile that holds water (snapshot flow >= `Q.WET_BUILD` 4) is not queued; kern.log `bed at x,y,z left out: the tile holds water N/7`, the part counts as refused (`R.uns`), the stage goes on. Other furniture and shallow seepage are untouched.
- Not changed: the site ranking and the aqshaft (BUG-482/484/490); nothing is dug near known water that the ranking did not already avoid.

## Tests
`tests/test_bug514_517_f32.py` (2: the stair tiles u/i/j in `s3.dig`, a deeper refuge), `tests/lua/test_bug514_wet_beds.lua` (2: a bed on water 7/7 left out and logged, seepage 2/7 queued).

## Live check
A fortcore stage 3 on its own: the stair column is dug from the refuge floor to the core level; kern.log `bed at ... left out: the tile holds water` where damp rock turned wet. Open: the wet tile is only seen when the chunk is applied; a level that turns wet later still cancels the bed in DF.
