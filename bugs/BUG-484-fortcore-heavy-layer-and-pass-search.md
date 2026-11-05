# BUG-484 fortcore stage 1 digs into a known heavy level; `aquifer=pass` finds 0 sites
Status: fixed (offline, live-untested)
Severity: high (Basementflew y388: fortcore @A46_61_131 stage 1 without p.aquifer met the heavy z116 again, AQ_HEAVY; `bp sites fortcore aquifer=pass --fresh` = 0 sites with the aquifer z116-z127 known and an aqshaft that had passed the light z127)
Found: 2026-11-05, Run 16a i1 Basementflew y388-y390 (FR-BUGS "fortcore stage 1 ohne p.aquifer grabt durch die schwere Schicht", "AQ_PASS_DONE ... fortcore aquifer=pass weiter 0 Sites")
Module: `dfpilot/bp/sites.py` (`_flooded`, `_rank_pass`, `rank`), `dfpilot/cmd.py` (`site_params`)

## Actual
1. plan propose drew fortcore stages 1-3 without p.aquifer although the manifest knew heavy levels (breaches why heavy_aquifer, z116/z123); `_flooded` returns at once when p.aquifer is set and otherwise only SCORED a known aquifer level (AQ_PENALTY), a heavy level too, so the best site still dug through it.
2. `bp sites fortcore aquifer=pass` ranked at the template's default depth 3: the core's deepest level (anchor z + ZE - 3 - refuge) can never lie under a level 12-17 below the surface, so `aquifer_ok` dropped every site and the answer was an empty list with no reason (no ValueError for fortcore; BUG-447 only did that for rooms).

## Root cause
`sites._flooded` (the early return for p.aquifer and no heavy rule); `sites.aquifer_ok` mode `pass` against a fixed depth; `rank` returned `[]` for the fortcore case without saying why.

## Fix
- `_flooded`: with no p.aquifer a candidate whose dig range (anchor + min(rects)..max(rects)) holds a level of `heavy_breach_levels(manifest)` (a dig of ours met a heavy aquifer there; the whole level counts, BUG-468) is dropped; if every site is, ValueError "heavy aquifer known at z.., another part of the map, or p.aquifer=pass (the aqshaft with its ring first, the core under the aquifer ...)". `p.aquifer=pass|above` is untouched (aqshaft with heavy ring, BUG-414). The BUG-388 area rule (`_dry`, LAYER_R) still applies to the pass cores.
- `rank` (fortcore, p.aquifer=pass, no p.depth) -> `_rank_pass`: the depth is chosen, from the first depth that clears the surface level up to the template's 12; every site names `depth` and the deepest core level in its reason line; `cmd.site_params` hands that depth to `bp.place` (like the aqshaft's), the later stages take it from the stage 1 file (BUG-364). When no depth up to 12 puts the core under the deepest known level the ValueError names the known/heavy levels, the surface level, the per-depth refusals and what to do (another part of the map, an aqshaft with its heavy ring down to the deepest layer and `bp sites fortcore aquifer=pass --fresh` again, stone and goods by caravan; no core is dug through a known layer without p.aquifer). RANK_V 9 (cached rankings are re-ranked).

## Tests
`tests/test_bug482_486_f30misc.py` (3: heavy level -> ValueError and no change for a level the dig never reaches, pass picks depth > 3 and the depth reaches the emitted doc, pass with no fitting depth says why), `tests/test_bug359_361_sites.py` (adapted: BUG-388's area rule under p.aquifer=pass, the plain stage 1 is refused).

## Live check
Basementflew-like fort (aquifer z116-z127, heavy z116/z123 recorded): `dfllm bp sites fortcore --fresh` no longer offers a site that digs through z116; `bp sites fortcore aquifer=pass` offers sites with `depth 12` (or says why none: the template digs 12 levels under the surface at most).
Open: the pass core is still limited to 12 levels below the surface; a heavy layer deeper than that needs a core placed where the aqshaft ends (not implemented); `plan propose` must draw the aqshaft first (BUG-412) - not changed here.
