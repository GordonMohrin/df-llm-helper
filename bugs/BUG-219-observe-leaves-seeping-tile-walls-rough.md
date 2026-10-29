# BUG-219 observe mode leaves the aquifer walls of later dug tiles rough
Status: fixed (offline, live-untested)
Severity: medium (an observed dig finishes with seeping aquifer walls open)
Found: 2026-10-29, live round 4 (Trussroads) and its skeptic
Module: `lua/dfllm/aqshaft.lua` (`A.wet`, `A.tick`)

## Actual
Observe mode smoothed only the walls beside the reported damp tile (`A.observe` adds the report position to `r.pts`,
`A.tick` seals around `r.pts`). DF reports damp for a tile with an aquifer neighbour, diagonals included, so the tiles dug
after the report sat beside aquifer walls no report named. They seeped (`AQ_SEEP 'seepage 1/7 at 46,67,124 (observe)'`,
45,67 and 47,67 still rough stone walls with the aquifer flag; in c1a1866e 48,71,124 flow 1 beside the rough 49,71, 48,70,
48,72, the report was at 47,71). `A.wet` recorded the seepage in `r.wet` and emitted AQ_SEEP but never added the tile to
`r.pts`, so both projects finished with those walls open.

## Fix
`A.add_pt(r, x, y, z)` (module field): dedupe, at most `obs_pts`, `{x, y, z, 'new'}`. `A.observe` uses it for the report
position; `A.wet` uses it on the first sample of a newly wet own tile. `A.tick` then smooths that tile's rough stone walls
(priority 1) on the next run, soil walls are noted as before.

## Tests
`tests/lua/test_bug219_seep_seal.lua` (runner world: a seeping tile 3 tiles from the report gets its 3 outside walls
smoothed; fake host: dedupe, the obs_pts cap, the soil wall left alone). Both fail on 5e9e719.

## Live check
On the next observe dig (AQ_OBSERVE) whose later tiles seep (AQ_SEEP at x,y,z): kern.log shows
`observe: N walls beside the damp tile x,y,z smoothed` for the AQ_SEEP position, and the rough aquifer walls orthogonal to
it get a smooth designation (later a smoothed wall); the seepage there stops or stays at <= 1/7.
