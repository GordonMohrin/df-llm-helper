# BUG-872 `bp sites cistern` found no site on i1 ('all 79 candidate site(s) lie on or right under a known aquifer level') and `water=aquifer` refused the whole z138 level for three single-tile heavy stops
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: cli.log 'all 79 candidate site(s) lie on or right under a known aquifer level (z135-z138)' and 'cistern water=aquifer: no site ... heavy (refused): z135,z136,z138'; i4 placed `bp.place tpl=cistern site=S1 water=aquifer` at once (4 water sources afterwards).

## Root cause
`dfpilot/bp/sites.py` `aquifer_well` took `heavy` per LEVEL (a set of z of every heavy_aquifer/water breach stop: three stops (44,86,135), (34,105,136), (24,103,138) refused every z138 basin of the fort, the 47 sites at x13-17 y72-76 are 27+ tiles from the nearest). `aquifer_ok` (rooms keep off z0..z1+1) makes the plain cistern fail by design once the sites left are at z139, and the kernel's recipe commands and the default call never name water=aquifer.

## Fix
(1) `aquifer_well`: heavy is a place: a basin is refused only within `HEAVY_NEAR` (10) tiles (Chebyshev, on the basin level) of a recorded heavy stop; the error names how many sites lost to a stop. (2) `cmd.cistern_aq_fallback`: a default cistern (no path, no water) whose plain ranking fails with the aquifer message is ranked / placed as `water=aquifer` when that ranking has a site: used by `rank_sites` (the default `bp sites cistern`) and `cistern_fill_guard` (`bp.place`, PLACE_NOTES 'BUG-872'). Nothing changes when a plain site exists, a path or a water is given, or no aquifer site exists (the old error stays).

## Tests
`tests/test_bug872_873_inside_water.py` (heavy far / near; fallback with a fake sites module: aquifer params, plain stays plain, neither keeps the error), `tests/bp/test_bug262_aquifer_well.py` (updated to the place rule).

## Live-Erwartung
On i1 `bp sites cistern` (no params) returns at least one site (the z139 sites at x13-17 y72-76 of the replayed snapshot) or a refusal naming the heavy stop within 10 tiles. That the basin there fills is NOT promised (i4: one aquifer cistern flips shallow/wet about monthly).
