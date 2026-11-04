# BUG-411 embark scan --hover: the merged read is optimistic (light aquifer shown, placed rectangle heavy)
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16d (i4 17,9 hover merge 'light aquifer', placed rectangle 'heavy aquifer + no_stone'; i2 similar), main 503bb8b
Module: `tools/embark/steps.lua`, `tools/embark/checklist.lua`, `tools/embark/embark.py`

## Actual
`scan --hover` printed `light aquifer` and `stone ok`; the same site placed (embark) showed the Confirm popup `heavy aquifer` and
`difficult to obtain stone`. 16b/16c: "Embark-Scan meldete light aquifer, tatsaechlich heavy".

## Root cause
- `steps.lua:merge_tiles` already took the worst evil/savagery/aquifer, but for STONE it kept the SHALLOWEST soil of the hovered tiles
  (`stone_soil`, 'a fort is dug where stone is near'): one shallow tile hid deep soil on the others. Right for a placed rectangle whose
  popup decides, wrong for a hover row, which has no rectangle and is read before the player chooses the local position.
- the summary did not say that a hover row covers only the hovered tiles (the rectangle placed later, or embark at another local
  position, has other tiles) nor that its tiles disagreed (a `light` row can hold `none`..`heavy`).

## Fix
- `merge_tiles(rec, tiles, opts)`: `opts.worst_stone` (set by `record` for a hover row) takes the DEEPEST soil for the stone criterion
  (`rec.tiles.worst_stone`; the stone item says "[deepest soil of the hovered tiles]"). Placed rectangles are unchanged.
- `rec.tiles.aq_best`: when the tiles differ the merged aquifer is the worst and the item says "(worst of the hovered tiles, best X)";
  the summary row shows `aq=heavy (tiles differ, best none)`.
- `embark.py summarize`: after hover rows one note: the merge is the worst aquifer and deepest soil of the hovered tiles only; the
  Confirm popup (embark gate) decides.

## Open
The popup of a hand-placed or `embark`-placed rectangle stays the only exact source; a hover row can still miss a heavy tile outside the
16 it hovered (a 6x6 or another local position). Worst-case stone makes hover rows stricter: one deep tile rejects the row (accept
with `--accept stone --explore-first ...` after a placed read shows otherwise).

## Tests
tests/lua/test_embark_fix22.lua (worst aquifer/soil merge, placed merge unchanged, aq_best), test_embark.lua / test_embark_fix6.lua
(expectations of the old optimistic merge updated), tests/test_bug409_411_embark.py (note, aq text).

## Live check
`scan 17,9 --hover` on the i4 world: the row shows `aq=... (tiles differ ...)` when tiles differ and the stone item names the deepest soil;
the note line follows the rows.
