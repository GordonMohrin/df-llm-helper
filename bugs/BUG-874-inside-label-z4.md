# BUG-874 a source inside a Z4 box of the fort that lies on no burrow was treated as OUTSIDE (i1 zone 18189 at 63,104,141 is in no Z4 box: it stays outside, see Live-Erwartung)
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank: kernel events #6172 'they stand at zone 18189 at 63,104,141, 14 tiles, the only accepted water of the fort (they went out to drink)'; state water.src_l ['zone 18189'] without ' in Kern+'; the manifest has only the burrow Kern+.

## Root cause
`lua/dfllm/water.lua` `s.inn` (the label `src_l`, `src_near`, `drink_fix`) came from `dfhack.burrows.isAssignedTile` of the Kern+ / refuge burrows only; a source in a Z4 box that is on no burrow (the manifest of i1 has only the burrow Kern+) read as outside. NOTE: the i1 zone 18189 itself lies in no Z4 box (checked against the live manifest).

## Fix
`M.in_fort_box(K, x, y, z)`: a tile inside a manifest `zones.Z4` box; `s.inn = 'fort'` when no burrow holds the source but a Z4 box does (label `zone N in fort`). The texts of siege / drink_fix therefore no longer say 'outside' for it. Reachability by walk group (the stranded groups of i1 cannot reach the pit tile) is NOT modelled here: the STRANDED rows keep naming the walk group.

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-874): a zone inside a Z4 box on no burrow counts as inside (`inw` 1, label `in fort`, no inside_water ask).

## Live-Erwartung
CORRECTED (verifier round 2, checked against the live i1 manifest `region1-site97/manifest.json`): zone 18189 at 63,104,141 lies in NO `zones.Z4` box (the 50 boxes hold z137-142: the nearest are [58,104,137,58,104,141] x58 only, [61,103,142,64,105,142] z142 only and [45,93,139,77,107,139] z139 only). So on i1 the zone is NOT 'in fort': `in_fort_box` is false, `inn` stays empty, state `water.inw` is 0 while no other accepted source stands inside, and the BUG-873 inside_water ask goes out (that is wanted: i1 has no accepted water inside). The earlier promise 'state water.src_l shows `zone 18189 in fort`' is WITHDRAWN. The change helps forts whose source lies in a Z4 box on no burrow; PROMISED only offline (test with the i1 box list: inw 0, one inside_water request). Reachability by walk group is not modelled here (BUG-875's retire check does it).
