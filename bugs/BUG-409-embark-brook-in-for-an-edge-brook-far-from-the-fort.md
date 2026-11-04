# BUG-409 embark scan: `brook=in` for a brook on the rectangle's edge, 95 steps from the fort
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Mansionlauded 18,22, `runs/run-16a/FR-BUGS.md`), main 503bb8b
Module: `tools/embark/embark.py`, `tools/embark/steps.lua`, `tools/embark/checklist.lua`

## Actual
`embark.py scan` / `embark` printed `brook=in (brook)` and the checklist passed `water: brook` for 18,22. The fort died of thirst in y373
(13 of 16): the only water was the brook at map y=0, 95 steps from the citizens, no `drink` class reach. The scan summary also named
brooks of other, far sites ("brook=47 tiles at 390,391", 160 tiles away, run 16d).

## Root cause
- `embark.py:brook_text` (line 260 before): `rec.water` set -> the text `brook=in (kind)`, no position, no distance. `rec.water` is
  true when ANY of the hovered tiles shows a brook; `rec.tiles.water_at` (the tiles) was only used when no brook was seen.
- `checklist.lua` (water): `if rec.water then put('water','pass')`: a brook on one rim tile and a brook through the middle were the same.
  i1 result (`dfllm-runtime/embark/result-embark1793825789.json`): `water_at` = 296,358 / 297,358 / 297,359, the rectangle 294..297 x
  358..361: top row and right column only (no inner tile); the rectangle's top row is the map edge.
- the 'none seen' branch searched the brook tiles of ALL scanned rows, whatever their distance.

## Fix
- `steps.lua` `S.water_geometry(wat, emb, size)`: tiles inside the rectangle, inner tiles (not on the outer ring) and twice the centre
  distance (a tile = 48 steps, 1.5 tiles = 72 steps, the i1 brook walked 95). `record()` stores `rec.tiles.water_n/water_core/water_d2`
  (not for a sweep).
- `checklist.lua`: a brook only on the outer ring is a `warn` ("brook only on the edge tiles of the rectangle (n tile(s), nearest 1.5 tiles
  = about 72 steps from the centre)"): the score drops (-12), the verdict stays; `best compromise` and the ranking see it.
- `embark.py` `brook_geometry` / `brook_text`: ` brook=in (kind) 3 tile(s), nearest 0.5 tiles (~24 steps) from the centre`,
  ` brook=EDGE ONLY (kind) ...`, ` brook=OUTSIDE the rectangle (...)` when every seen brook tile lies beyond the rectangle,
  ` brook=in (kind) (tile positions not read: scan --tiles)` without positions. The 'none seen' search takes only brook tiles within
  `BROOK_NEAR` (16) tiles of the rectangle.

## Open
The panel marks a TILE; where the brook runs inside a 48-cell tile is not shown, so ~72 steps is the nearest centre distance, not a
path. No walk-group or reach check is possible before the embark. `bp sites` / the plan side of the same death (rank without reachable
water, automatic water access) is a different fix.

## Tests
tests/lua/test_embark_fix22.lua (geometry, edge-only warn, inner pass), tests/test_bug409_411_embark.py (brook text, near search),
tests/test_bug245_250_embark_tools.py (summary lines updated).

## Live check
`embark.py scan 18,22,6,6` (and `--hover`): the row shows `brook=EDGE ONLY ... ~72 steps` and `water` warn; a rectangle with a brook
through its middle shows `brook=in ... (~24 steps)`.
