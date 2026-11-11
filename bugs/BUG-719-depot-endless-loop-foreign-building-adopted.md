# BUG-719 Depot endless loop: any building in the 5x5 counted as the depot, the project was 'done', no depot stood
Status: fixed (offline, live-untested)
Severity: high (no caravan could unload: no trade, the project queue hung behind it)
Found: 2026-11-11, Run 16c i3 Doorwings y372 (depot1..25 at 94,98,148, the aqshaft anchor; inspect trade 'no built trade depot'), Run 16d i4 Pagedsculpture y372 (depot1..15 at 96,95,142 with a stair 95,94,142, a passable 98,93,142 and 12 of 25 footprint tiles no open floor); kern.log `queued depotN` / `depotN (depot) done` 5 s apart, DEPOT_MISSING, NO_DEPOT
Module: `lua/dfllm/runner.lua` (`pre_occupied`, `cell_present`, `Q.depot_fallback`, `M.depot_keep`, new `Q.depot_avoid`, `Q.depot_block_why`)

## Root cause
1. `runner.lua` `pre_occupied` (live L2, 'a stage placed again over buildings it already has'): every tile of the depot's 5x5 footprint ('D(5x5)' is one cell, `cell_tiles` yields 25 tiles) that held ANY building was adopted as the project's own building (`R.b`); `measure_build` read it as built, the stage was 'done' 100 % although quickfort refused the 5x5. `cell_present` accepted any building on the corner the same way.
2. `Q.depot_fallback` (BUG-612) proved only the walk group of the 25 tiles and the '.' of the MIDDLE tile: a stair is walkable and shares the group, an open aqshaft's anchor is plain floor, so the site lay on another project's tiles.
3. `M.depot_keep` set `S.rt.depot` to the fallback site, so every new project went to the same bad site: 25 times.

## Fix
- `pre_occupied` / `cell_present`: for the key `D` only a trade depot is the depot's (a pre-existing one is still adopted); anything else in the footprint is an unsuitable tile, the stage is `build_lost` with the BUG-536 reason (`lost_why`).
- `Q.depot_fallback`: all 25 tiles must be open floor on the snapshot (no building, no designation, not hidden) and none may lie in another open project's tiles (`Q.depot_avoid` = `own_tiles` of every non-depot project not done); a remembered fallback site is re-checked the same way.
- `M.depot_keep`: a depot project that reported done (and never stood) or is `build_lost` twice marks its site bad (`m.runner depot_bad`), a lost one is cancelled with undo, the next site is searched at once; after `depot_resite_max` (4) failed sites the keeper stops with one kern.log line (`no depot site stood the build`). A site that once held a depot (`depot_stood`) is never marked bad (a razed depot is rebuilt where it stood, FR-43).

## Tests
`tests/lua/test_bug719_depot_site.lua` (4): a construction on the corner is no depot (stage `build_lost`, no PROJECT_DONE) and a trade depot there is; the fallback site is open floor on all 25 tiles and keeps off an aqshaft project's tiles and a stair; a done-without-depot project is given up, each next project has a new site, the keeper stops after `depot_resite_max`; a project `build_lost` twice is cancelled and re-sited. The fake world (`runner_world.lua`) gets `TradeDepot` and builds `D` as one.

## Live check
kern.log: at most one `queued depotN` per site, `trade depot site x,y,z given up (...)` naming the reason; inspect trade shows a built depot; no `depot6` while the first stands.
Open: a manifest depot site (fortcore) is not re-checked (the plan's); whether DF's quickfort counts a depot footprint tile of 'passable' / a trap as unsuitable is read from the BUG-536 live text, not measured; the CLI template path `bp.place depot` (`bp sites depot`) is unchanged.
