# BUG-323 a way in on a sapling is left out by seal at=last when no neighbour closes it; regrowth keeps R0 open
Status: partly fixed (offline, live-untested): the sapling case; the recurring floor ways in under tree crowns are open (see Open)
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

## Open (review, 2026-10-29; read-only evidence, not fixed)
The sapling case is 2 of about 25 ways in SIEGE_UNREADY named y374-y377 (events.jsonl). Most are `floor` tiles that come and go
without a seal (`87,100,133 floor` in 7 events, `76,87,133`, `78,97,133`; far ones `16,95,133`, `106,63,133`, `124,23,135`), and the
open count drops to 0 and back (pd 2, 40, 79, 2, 0, 28, ...). On snapshot s152283619-4 every named z133 tile (87,100 79,85 78,97 92,81)
has a `.` on z134 above it, and z134 over the forest is the tree canopy (snapshot.SHAPE draws BRANCH and TRUNK_BRANCH as `.`; DESIGN:
"a tree crown counts as a roof"). The entrance check (seal.lua bfs eval, `des.outside`) reads canopy-roofed surface tiles as inside, so
the fort's interior runs out through the crowns, and its rim (the openings) moves as crowns grow and branches fall. A door on such a
rim tile closes nothing for good. Likely fix (kernel, needs a live look first): a tile whose roof is only tree (BRANCH/TRUNK_BRANCH/TWIG
or leaves above, no natural or constructed floor) counts as outside in the entrance check, so the openings are the fort's real mouths.
Live check first: `dfllm cmd inspect what=entrances` on Inkintense, and in DF the tile 87,100,133 (Outside/Inside) and what is above it.

