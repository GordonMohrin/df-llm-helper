# BUG-633 A cavern_lake breach in a flooded self-dug room on the aquifer level refuses every aqshaft column of the fort
Status: fixed (offline, live-untested)
Severity: high (i3 Wallfree: `bp sites aqshaft` refused 297 -> 478 columns for years, no way down to the core)
Found: 2026-11-10, Run 16c i3 Wallfree y376-y383 (round19_notes X1): manifest `caverns` = `[[97, 59, 143]]` (`breaches`: explore `y374s1b0`, why `cavern_lake`; the aquifer levels are z141-z143); `cli.log`: `an avoided cavern/warm level: 478 [100,24: cavern/warm level z143 (cavern breach at 97,59,143) lies within the shaft's z146-z139 or the level below it`
Module: `dfpilot/bp/sites.py` (`CavernLevels`, `shaft_avoid`, `shaft_why`, `core_shaft`)

## Actual
Every column from every public Z4 floor tile (the fort is 80 tiles wide) was refused for `z143`.

## Root cause
`sites.py shaft_avoid` made the level of every recorded cavern breach a whole-level avoid (BUG-432: "a cavern is a volume"). The only exception was a breach that was also an aquifer breach (`heavy_aquifer`, `damp`, `water`) in the known aquifer span; this one was classified `cavern_lake` (water around a flooded room of ours with a cavern-flagged tile beside it) although z143 is an aquifer level and no revealed cavern mark exists on it.

## Fix
`shaft_avoid`: a recorded cavern breach on a KNOWN AQUIFER LEVEL (`known_aquifer`: manifest levels, revealed aquifer tiles, wet layers from the breaches) with no revealed cavern / warm mark on that level is kept as a LOCAL entry (`CavernLevels.local`): `hits(lo, hi, x, y)` refuses only the columns within `AQ_LAKE_R` (8) + 1 tiles of the breach on x/y and says so (`N tiles from the column; a column more than 9 tiles away passes`). A breach on a non-aquifer level, or a level with a cavern mark, stays level-wide (BUG-432); `hits` without x/y (other callers) stays level-wide too. `shaft_why` and `core_shaft` pass the column's x/y; `bp.place aqshaft` with p.x/p.y/p.top (`check_column`) uses the same rule, so a hand-named column away from the breach passes.

## Tests
`tests/test_bug631_633_f41_aqring.py` (local refusal and distance text, off-aquifer / marked levels stay level-wide, the ranking offers only columns beyond the radius).

## Live check
i3-like manifest: `bp sites aqshaft --fresh` lists columns more than 9 tiles from 97,59 (the aqshaft's own ring/pre-ring then handles z141-z143); the refusal for a column beside it names the distance.
Open: a real cavern lake that reads as an aquifer level (a cavern layer inside the aquifer span) would be passed at 9+ tiles; the aqshaft watches every level it opens (AQ_HEAVY / breach:cavern_lake still stop it). The radius is not measured in DF.
