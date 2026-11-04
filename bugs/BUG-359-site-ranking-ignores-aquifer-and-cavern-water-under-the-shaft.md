# BUG-359 site ranking ignores the aquifer and cavern water under the fortcore shaft
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 16c (i3, r16c-w9-18-site97), main 595364a
Module: `dfpilot/bp/sites.py`, `lua/dfllm/snapshot.lua`, `dfpilot/schema.py`

## Actual
Every reachable fortcore site of the fort broke into water: A74_92_125_3 `breach:heavy_aquifer` (breach 119,92,118),
A88_92_125_3 `breach:cavern_lake` (122,89,120), A106_78_125_1 `dig_lost`; the manifest ended with `aquifer_levels`
[120,122] and both breaches, the embark panel and `bp sites fortcore` only said 'light aquifer' / nothing. The fort stood
without buildings, pop 13 on fishing.

## Cause
- `sites.py` `_dry` (BUG-130) counted a level as a wet layer only for breach labels whose first word is `damp` or `water`:
  a `heavy_aquifer` stop (label `heavy_aquifer x,y,z proj`) counted as a pocket 10 tiles wide, so the next ranking offered
  sites a few tiles away that dug through the same aquifer level (a whole level, z118).
- `rank` rated nothing under the anchor for fortcore unless p.aquifer was set (`aquifer_ok`: manifest `aquifer_levels`
  only); the snapshot carried no aquifer information at all, revealed water or cavern tiles beside the deep dig (outside
  the rects `_check` looks at) were not looked at, and the reason line never said what was known.

## Fix
- `_breach_layers`: one `heavy_aquifer` stop makes its level a wet layer (damp/water keep the two-stop rule); `_dry` drops
  every site whose dig passes it.
- `_flooded` (fortcore, p.aquifer unset): drops a site when revealed water lies within `FLOOD_R` (4) of a deep dug rect
  (levels -3 and deeper); penalizes `AQ_PENALTY` (250) per known aquifer level the dig passes and `CAV_PENALTY` (150) per
  level with a revealed cavern beside it; the reason line says `aquifer at z120,z122`, `cavern near z..` or `no aquifer or
  water known on z117-125 (hidden rock is unknown)`; ValueError `no site clear of water below` when every site is dropped.
- `known_aquifer` = manifest `aquifer_levels` + snapshot `aqz` + breach layers; `aquifer_ok` (rooms, fortcore
  above/pass) uses it too, so every dug template keeps off levels a snapshot or a breach shows wet.
- snapshot.lua: a `sites` export counts revealed tiles with the aquifer flag per level (`aqz`, `M.revealed_aquifer`, a
  hidden tile is never read). Contract: snapshot `aqz?` (schema.py, CONTRACTS, appendix). RANK_V 4.

## Tests
tests/test_bug359_361_sites.py (fail on 595364a), tests/lua/test_snapshot_aquifer.lua (2).

## Live check
`bp sites fortcore --fresh` on a fort with a recorded heavy_aquifer breach: sites passing that level are gone, the others
say `aquifer at z..` or `no aquifer or water known`; the snapshot file of a sites export has `aqz`.
Open: below hidden rock nothing is known (fair play); a first dig can still meet an aquifer the snapshot cannot show.
