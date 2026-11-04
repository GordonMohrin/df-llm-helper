# BUG-333 status and inspect entrances name other ways in; a sapling way in off the snapshot is left out by seal at=last
Status: partly fixed (offline, live-untested): one list for status / inspect / seal, saplings off the snapshot; open: the
recurring ways in on the open surface (tree canopy read as roof, BUG-323 Open)
Severity: medium
Found: 2026-10-29, Run 15b/15c/15d (Earthboat y385, Inkintense y374-y377, Drillchamber y377-y379)
Module: `lua/dfllm/seal.lua` (inspect.entrances), `dfpilot/cmd.py` (seal_openings)

## Actual
1. Earthboat y385 (SIEGE): `PERIMETER OPEN 46 days: 2 ways in` beside `ways in: all with a door or bridge`, `seal at=last`
   `nothing to close`. That is BUG-322 (fix13); live now: Earthboat state in SIEGE has `ready.open 0, pd/pw` unset (read-only
   check 04.11., state.a/b.json tick 142685/142746). No new change.
2. Drillchamber y377 spr d4: status `3 ways in without door or bridge: 12,170,146 sapling, 14,170,146 sapling, 11,169,146
   sapling` (SIEGE_UNREADY #1992: open 3, routes 4); `inspect what=entrances key=refresh` named `opening 120,126,144 floor no
   door`. `bp.place tpl=seal at=last` and after `bp sites seal --fresh` (cli.log 1793287951): `nothing to close ... 12,170,146
   sapling: left out, its tile is not on the snapshot`; 21,85,146 sapling the same (1793283019).
3. Inkintense/Drillchamber: shrub/sapling/floor ways in on the open surface come back 2-3 times a year; R0 open_perimeter
   rarely clears (events y376-y379: 27,169,131 floor, 79,85,133 sapling, 17,88,146 floor, 16,89,146 shrub, ...).

Root causes:
- (2, list) `lua/dfllm/seal.lua:5458-5477` (9b6f614) `inspect.entrances` answered with `openings` (each route's nearest tile
  `pos`) and counts, while status, SIEGE_UNREADY and `seal at=last` read `entrance_doors().open` (readiness.lua:219): for an
  opening the exposure flood entered by, its gap tiles (BUG-031), which can lie far from its `pos` on a long surface rim.
  Two lists of one check.
- (2, seal) `dfpilot/cmd.py:1110` (9b6f614): a sapling counts as `needs_neighbour`; without its tile on the snapshot no
  neighbour can be searched and it was left out, although BUG-323 puts the piece on the sapling itself when no neighbour
  closes it (quickfort checks the tile when it places it).
- (3) not fixed: see BUG-323 Open (tiles roofed only by tree crowns read as inside by `des.outside`; needs a live look).
  The shrub case is not left out by the code (BUG-041: the piece on the shrub); the `54,46,146 shrub: left out` of
  Drillchamber's round 4 note was the old sapling path (cli.log 1793299749 `45,77,146 sapling`, before fix13).

## Fix
- `inspect what=entrances`: `data.ways` = the open tiles exactly as status names them (`x,y,z kind`, entrance_doors), the
  message adds `(ways in as status names them: ...)` (first 3).
- `seal_openings`: a sapling whose tile is not on the snapshot (or no snapshot) gets its piece on the sapling (`x,y,z floor`),
  note `not on the snapshot, the piece goes on the sapling`. Doors and buildings off the snapshot still wait for it.

## Tests
`tests/lua/test_bug333_ways_one_source.lua` (1, fails on 9b6f614: no `ways`), `tests/bp/test_bug333_sapling_off_snapshot.py`
(2; the sapling test fails on 9b6f614 with `nothing to close`).

## Live check
After a kernel reload: `dfllm cmd inspect what=entrances key=refresh` shows `ways in as status names them: ...` with the same
tiles as `dfllm status`. Drillchamber/Inkintense: the next `seal at=last` with a sapling way in off the snapshot queues
`x,y,z floor` with the note. Open: whether the surface ways in sit under tree crowns (in DF: the tile's Inside/Outside and the
tile above it); if so, BUG-323's proposed rule (a tile roofed only by tree counts as outside) is the next step.
