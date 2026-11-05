# BUG-432 `bp sites aqshaft` refuses every column for a cavern/warm level far below the shaft's goal
Status: fixed (offline, live-untested)
Severity: high (Gordon's top priority "forts go under the aquifer": no shaft is ever drafted or placeable)
Found: 2026-11-05, Run 16c i3 Yawninggilt, main ad01acb (`runs/run-16c/FR-BUGS.md`, "OBS Fix-Runde 25")
Module: `dfpilot/bp/sites.py` (`_aqshaft`, `core_shaft`), `dfpilot/plan.py` (`aquifer_route`)

## Actual
Aquifer z120-127, a cavern breach recorded below it (manifest `caverns`). After fix round 25 `plan propose` still drafted no aqshaft ("no fortcore site with a safe shaft
column below the aquifer ([20, 62, 127]: aqshaft beside the...)") and `bp sites aqshaft` (also `depth=5..20`) said "no column ... rock 0 refused; an avoided cavern/warm level: 1271".

## Root cause
`sites.py _aqshaft` (old line ~1306): a column was refused when ANY cavern/warm level lay in `az - p.depth + 1 .. az`, and `p.depth` defaulted to 20, far deeper than the shaft ever has to
go. The shaft only has to reach the core's refuge level (the core level two under the shallowest aquifer level + the 3-level refuge). A cavern deeper than that is none of the shaft's business,
but with depth 20 from z127 every one of the 1271 columns "reached" it. `core_shaft` (the route's column) had the same any-level rule over its own, correct, levels.

## Fix
- `shaft_depth_auto`: without `p.depth` the ranking goes down to `AQ_REACH` (5) levels under the shallowest known aquifer level (else 20 as before); each ranked site carries its `depth`
  (the `why` says `p.depth N`), `cmd.site_params` hands it to the emitted shaft (bp.place / free scan / rank), `RANK_V` 8 re-ranks old caches.
- `shaft_why`: a cavern/warm level refuses a column only within the shaft's own levels and the ONE level right below its bottom (never open into one); deeper ones do not matter. `core_shaft`
  uses the same window.
- A given `p.depth` is still checked as given.
- Verifier round: the window was still level-wide (i3: breach (50,63,122) inside the aquifer z120-127, every shaft passes z122). Now local: `CavernPoints` keeps the
  revealed cavern/warm marks and manifest `caverns` as points; a column is blocked only by one within `AQ_CAV_R` (8) tiles (x/y) on its levels or the one below its bottom
  (`shaft_why`, `core_shaft`).

## Tests
`tests/bp/test_bug432_433_aqshaft_depth.py` (aquifer z5, cavern at z-10: ranks with depth 6; depth 20 refused naming z-10; cavern 1 level below the bottom refused, 2 below fine; i3 case: a breach at z3 inside the aquifer span refuses only columns within 8 tiles), `tests/test_bug412_413_aquifer_default.py` (core_shaft).

## Live check
i3: `dfllm bp sites aqshaft --fresh` ranks columns (`p.depth N`); `plan propose` drafts `aqshaft` (route or `aquifer_late`).
