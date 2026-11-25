# BUG-872 `bp sites cistern` found no site on i1 ('all 79 candidate site(s) lie on or right under a known aquifer level') and `water=aquifer` refused the whole z138 level for three single-tile heavy stops (the level refusal STAYS, see Fix)
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: cli.log 'all 79 candidate site(s) lie on or right under a known aquifer level (z135-z138)' and 'cistern water=aquifer: no site ... heavy (refused): z135,z136,z138'; i4 placed `bp.place tpl=cistern site=S1 water=aquifer` at once (4 water sources afterwards).

## Root cause
`dfpilot/bp/sites.py` `aquifer_well` took `heavy` per LEVEL (a set of z of every heavy_aquifer/water breach stop: three stops (44,86,135), (34,105,136), (24,103,138) refused every z138 basin of the fort, the 47 sites at x13-17 y72-76 are 27+ tiles from the nearest). `aquifer_ok` (rooms keep off z0..z1+1) makes the plain cistern fail by design once the sites left are at z139, and the kernel's recipe commands and the default call never name water=aquifer.

## Fix
(1) `aquifer_well`: a level with a recorded heavy_aquifer/water stop stays refused AS A WHOLE (verifier retry: a stop is only where one dig happened to meet visible water; a level with no stop 11 tiles away is untested, not light, and the same layer is probably heavy across the region; the first version's 10-tile distance rule had no evidence behind it and is gone, so on i1 the z135/z136/z138 basins stay refused and that is the SAFE outcome). New hard-rule refusal `_aq_hazard`: a site is refused when open water (`~ w`), magma (`%`) or open space (`_`, a drop: no floor) lies within `AQ_KEEP` (3) tiles (x/y) of its footprint on the basin level, the room level (and water on the level above); the error names the count and one example. (2) `cmd.cistern_aq_fallback`: a default cistern (no path, no water) whose plain ranking fails with the aquifer message is ranked / placed as `water=aquifer` when that ranking has a site: used by `rank_sites` (the default `bp sites cistern`) and `cistern_fill_guard` (`bp.place`, PLACE_NOTES 'BUG-872'). Nothing changes when a plain site exists, a path or a water is given, or no aquifer site exists (the old error stays).

## Tests
`tests/test_bug872_873_inside_water.py` (heavy level refused as a whole; fallback with a fake sites module: aquifer params, plain stays plain, neither keeps the error), `tests/bp/test_bug262_aquifer_well.py` (level refusal near and far from the stop, a stop on another level does not matter, open water / magma / drop at 3 tiles refuses the site for the basin and the room level, 5+ tiles off it does not, error names the hazard).

## Live-Erwartung
Preconditions and NON-promises (verifier retry):
- On i1 `bp sites cistern` (no params) falls back to `water=aquifer` only when an aquifer site passes ALL refusals. i1's manifest holds heavy stops on z135, z136 and z138, so the z138 basins (the 47 z139 sites) stay REFUSED: the call keeps its error, now naming `heavy (refused, a level is heavy as a whole): z135,z136,z138`. NOT promised: that i1 gets an aquifer cistern by this fix. i1 can get one only on a level without a heavy stop (a deeper or a not yet dug level; an aqshaft that meets damp stone shows one) or by the other options (piped cistern, bucket-fed with a fill source).
- The i4 case (no heavy stop on the basin level z138) still works: `bp sites cistern water=aquifer` returns sites.
- The hard rule holds for this path: a site within 3 tiles of open water, magma or a drop is refused; the hazard test reads the REVEALED tiles of the sites snapshot only (an unrevealed `?` tile counts as rock, as everywhere in the ranking).
- Even a placed aquifer cistern needs its well parts (see BUG-873): without a free mechanism / block / bucket / chain the well stays unbuilt. That the basin fills is NOT promised (i4: one aquifer cistern flips shallow/wet about monthly).
