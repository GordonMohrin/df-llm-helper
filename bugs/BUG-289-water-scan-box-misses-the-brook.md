# BUG-289 the water scan's box misses the brook the fort drinks from
Status: fixed (offline, live-untested)
Severity: high (Run 15 Drillchamber: hospital water red since y372; the scan saw 1 tile at 87,82,141 while the brook 141,67,143
(n=158 in round 1) lay outside its box)
Found: 2026-10-29, Run 15 round 2 (Drillchamber FR-BUGS: `boxes [[64,43,136,124,103,142]]`)
Module: `lua/dfllm/water.lua` (new_scan, scan_survey, scan_seed, scan_group, M.recipe, M.best_way), `lua/dfllm/snapshot.lua`
(liquids lattice, map_size, surface_z), `dfpilot/cmd.py` (water_ctx), `dfpilot/bp/sites.py` (_near_water)

## Actual
The box was the hospital zone (else the citizens' median) +- `near` 30 tiles and +- 3 levels (05dc764 water.lua:731-756). Water
farther away was never read, even when the citizens drank there; a body beyond 30 tiles was never offered either.

## Fix
Besides that box: a box round every citizen (+-10, +-1 level), round each body the last scans found (m.water `wb`, 8), a survey
of the whole map's surface levels (the surface at the reference column and the map centre, 2 levels each, every 3rd tile on the
lattice (x + 2y) % 3 == 0 through `snapshot.liquids` lattice: a brook 1 tile wide is met every 3 tiles; at most 36,000 tiles) and a
+-10 box round what the survey met (at most 9,000 tiles), all within the read budget; revealed tiles only. The three largest bodies
stay in the list beside the nearest ones. A reachable body beyond `near`: the recipe says 'zone it as Water Source from the bank at
..., then the hospital within 30 tiles of it'; state `water.wsc` names the best way to water at any distance and `bp sites
hospital` quotes it when no accepted water exists.

## Tests
`tests/lua/test_bug288_291_water_scan.lua` (far brook found by the survey, read whole, remembered; a citizen beside water; box
merge), `tests/bp/test_bug292_aqshaft_sites.py` (bp sites hospital names the scan's way). Fail on 05dc764.

## Live check
Drillchamber: `inspect water_sources` lists a body near 141,67,143 with a bank, `survey` [143,142]-like levels and `seeds` >= 1;
`way` and state water.wsc name it; HOSPITAL_DRY's recipe names the bank. Uncertain: whether the surface level of the reference
column hits the brook's level (a hill or a pit there) and whether 2 levels suffice on a sloped map.
