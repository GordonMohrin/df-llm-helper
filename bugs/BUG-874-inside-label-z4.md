# BUG-874 zone 18189 at 63,104,141 inside the fort core's Tiefe+ box was treated as OUTSIDE ('they went out to drink: bring water inside first')
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank: kernel events #6172 'they stand at zone 18189 at 63,104,141, 14 tiles, the only accepted water of the fort (they went out to drink)'; state water.src_l ['zone 18189'] without ' in Kern+'; the manifest has only the burrow Kern+.

## Root cause
`lua/dfllm/water.lua` `s.inn` (the label `src_l`, `src_near`, `drink_fix`) came from `dfhack.burrows.isAssignedTile` of the Kern+ / refuge burrows only; the Tiefe+ box x45-77 y90-107 z138-141 has no burrow in the manifest (why the tile is on no burrow: unconfirmed).

## Fix
`M.in_fort_box(K, x, y, z)`: a tile inside a manifest `zones.Z4` box; `s.inn = 'fort'` when no burrow holds the source but a Z4 box does (label `zone 18189 in fort`). The texts of siege / drink_fix therefore no longer say 'outside' for it. Reachability by walk group (the stranded groups of i1 cannot reach the pit tile) is NOT modelled here: the STRANDED rows keep naming the walk group.

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-874): a zone inside a Z4 box on no burrow counts as inside (`inw` 1, label `in fort`, no inside_water ask).

## Live-Erwartung
On i1 `inspect water_sources` / state water.src_l shows `zone 18189 in fort`; stranded_drink does not say 'outside' for it (PROMISED). That the stranded citizens can reach it is NOT promised.
