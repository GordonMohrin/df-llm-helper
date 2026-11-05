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
- `shaft_depth_auto`: without `p.depth` the ranking goes down to `AQ_REACH` (2) levels under the shallowest known aquifer level = the core's top level (a core keeps off the aquifer level and the one right
  under it, `aquifer_ok`); NOT the refuge room 3 levels deeper (every extra level is one more to keep cavern-free). Else 20 as before. Each ranked site carries its `depth` (the `why` says `p.depth N`),
  `cmd.site_params` hands it to the emitted shaft (bp.place / free scan / rank), `RANK_V` 8 re-ranks old caches.
- `shaft_why`: a cavern/warm level refuses a column only within the shaft's own levels and the ONE level right below its bottom (never open into one); deeper ones do not matter. `core_shaft` uses the same window.
- A given `p.depth` is still checked as given; the explicit column (BUG-433) goes through the same rules.
- Verifier rounds: a local 8-tile radius (b5fad6a) was rejected as a cavern-safety regression: marks are sparse (`marks.cavern` is cut at 500 per export in scan order, low z first), a manifest `caverns` entry is ONE
  breach point of a large volume, unrevealed tiles pass. Restored level-wide: `CavernLevels` ({z: evidence} of revealed cavern/warm marks and manifest `caverns`) refuses every column touching such a level; the
  refusal names the level and the evidence coordinate. New: (a) a `caverns` point that is also an aquifer breach (`breaches` why heavy_aquifer/damp/water at the same position) inside the known aquifer span is
  the aquifer itself and is skipped; (b) a `marks.cavern` list at the cap (500) means coverage incomplete: the levels from its last mark up were not scanned, a shaft touching one is refused level-wide.

## The i3 breach, evidence (read-only, E:/DF-test3/dfllm-runtime/r16c2-w6-17-site97)
manifest: `caverns [[50,63,122]]`, `aquifer_levels [121,122,123,124]`, `breaches` entry `{"pos":[50,63,122],"proj":"y375s1b0","tpl":"explore","why":"cavern_lake"}`; events.jsonl n=1064 `BREACH_STOP`
why=cavern_lake "cavern lake (tile, not water: 154 water tiles in reach)", n=1065/1069/1090 CAVERN_PLUG (the explore shaft 50,63 was walled at z125). So it is a REAL cavern_lake breach (`caverns` is only fed by cavern /
cavern_lake stops, runner.lua note_cavern), lying inside the aquifer span. Every shaft that reaches the core under the aquifer passes z122, so on i3 every column is refused (honest result, as before BUG-432's
first round): the shaft cannot stay above that level (the aquifer spans it). Only a cavern-free aquifer span, or a manual decision by Gordon, gives an aqshaft there.

## Tests
`tests/bp/test_bug432_433_aqshaft_depth.py` (12: auto depth = core level; cavern far below refuses nothing, depth 20 refused naming z-10; level right below the bottom refuses, two below fine; sparse marks and warm
mark refuse the whole level; large cavern with one far breach point refuses every column; aquifer-breach point inside the span skipped, same point as cavern_lake refused; capped marks = incomplete coverage),
`tests/test_bug412_413_aquifer_default.py` (core_shaft level-wide), `tests/bp/test_bug292_aqshaft_sites.py`.

## Live check
i3: `dfllm bp sites aqshaft --fresh` is expected to STILL refuse (cavern_lake z122 inside the aquifer) with a message naming z122 and the breach coordinate; a fort without a cavern in the aquifer span ranks columns (`p.depth N`).
