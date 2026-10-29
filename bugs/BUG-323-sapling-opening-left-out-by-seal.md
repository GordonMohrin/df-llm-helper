# BUG-323 a way in on a sapling is left out by seal at=last when no neighbour closes it; regrowth keeps R0 open
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15c (Inkintense, live, y376 win - y377 sum)
Module: `dfpilot/cmd.py` (seal_openings)

## Actual
Inkintense's ways in come and go on the open surface z133 by the fort (SIEGE_UNREADY ents y375-y377: `86,100,133 sapling`,
`87,100,133 floor` -> `shrub` -> `floor`, `84,83,133 shrub`, `79,85,133 sapling`, `87,73,133 shrub`, ...; the tiles regrow plants
2-3 times a year). `bp.place tpl=seal at=last` (cli.log 1793295288, c1a188ba863f982d01): `79,85,133 sapling: left out, no single
neighbouring tile closes its route on the snapshot`; nothing ever closed that way, open_perimeter never cleared and its day count
restarted with every change (pd 2, 40, 2, 14, 2).

Root cause: `dfpilot/cmd.py:1073-1090` (1d17c7e): a sapling counts as `needs_neighbour` (bp/defense.py FOR_WHY "no piece and no
player designation takes a sapling"); when SealGeo.neighbour finds no tile that closes the same route (open ground: the hall wide
behind the mouth, open sky before it) the opening was dropped with a note. But quickfort builds doors and constructions on SAPLING
tiles (DFHack 53.16 internal/quickfort/build.lua:49-58 is_valid_tile_generic, :107-119 is_valid_tile_has_space), as on shrubs (BUG-041).

## Fix
seal_openings: a sapling no neighbour closes gets its piece on the sapling itself, read as floor (`x,y,z floor`; door, or a wall
when no wall stands beside it, `nodoor` as for any floor), note `... no neighbour closes its route, the piece goes on the sapling
(quickfort builds on sapling tiles)`. The neighbour stays first where one exists (Run 11 behaviour unchanged).

## Tests
`tests/bp/test_bug323_sapling_seal.py` (2; the sapling test fails on 1d17c7e with `nothing to close`, the shrub guard passes on both).

## Live check
Inkintense: the next `dfllm cmd bp.place tpl=seal site=S1 at=last` with a sapling way in prints the note and queues the piece on
the sapling; the SEAL_STUCK of that piece (if any) names why DF does not build it (the runner walls a door that stays stuck).
Uncertain: whether DF's builder accepts a sapling tile as quickfort's placement does; whether tree crowns that grow from saplings
make new roofed ('inside') tiles on the surface and so new openings (not decidable offline).
