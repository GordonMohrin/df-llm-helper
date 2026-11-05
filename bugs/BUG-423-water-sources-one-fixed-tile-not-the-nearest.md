# BUG-423 water_sources reports one fixed tile per body, not the water nearest to the fort
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-05, Run 16a i1 Manorsubtle y372-374 (`runs/run-16a/FR-BUGS.md`, runtime `r16a3-manorsubtle-site97/cli.log` line 315), main 03f4c1a
Module: `lua/dfllm/water.lua` (`scan_group`, `scan_body`, `drink_access`), `lua/dfllm/economy.lua` (`M.no_water`)

## Actual
The brook ran in a rock gully ~8 tiles east of the start room (x102-106, y72+). `inspect what=water_sources` knew ONE body of 1229 tiles with the
representative tile `10,0,158` (the map edge), reach 0, no bank, no dig, no well spot. DECISION_NEEDED `thirst` named
`a cistern piped to it (... bp sites cistern --near 10,0,158)` and the command answered `no site within 20 tiles of 10,0,158; the nearest
candidate 94,86,154 is 82 tiles away`. 13 of 15 died of thirst.

## Root cause
`water.lua` `scan_group` (sort of `body.tiles` by y, then x; `body.at = body.tiles[1]`): the representative tile of a body is its
northernmost-westernmost one, whatever the body's shape. A long brook is one 8-connected body, so `at` lay at the map edge; the distance `d` was the
nearest one (the box distance), but the tile that went with it was not reported. Second effect of the same sort: `scan_body` reads the neighbours of
`body.tiles` in that order and stops at `ws_reads` (400): for a 1229-tile body the bank / dig search spent all its reads at the far end and never looked
at the tiles beside the fort (`partial`). `recipe` / `drink_fix` / `p.wb` (the memory of the next scan) all use `at`.

## Fix
- `scan_group`: the tiles are sorted by their distance to the fort (the reference box: hospital or the citizens' median) or to the nearest of the scan's
  walk origins (`sc.froms`, the citizens), Chebyshev first, the squared distance as the tie-break, then y, x. `body.at` is the water tile NEAREST to
  the fort or a citizen; `nd` = that distance, `ext` = {x0, y0, x1, y1} of the body. `scan_body` therefore starts its bank / dig / pit search there.
  `d` (the box distance used by the recipes) is unchanged.
- `water.drink_access`: `near` {x, y, z} and `nd` of the nearest body without a bank (cavern water never).
- `economy.no_water`: the DECISION carries `near`, `nd` and the command `python -m dfpilot.bp.sites cistern --near <that tile> --radius 20`.
  `water.recipe` names `far.at`, which is now that tile.

## Open
- One tile per body still: two arms of a brook far apart are one body (8-connected); the nearest tile is what matters for a fort, the farther arm is
  reported by `ext` only. A body larger than the scan box is cut at the box.
- `at` changed meaning for its readers: `p.wb` (the next scan's boxes) now centre on the nearest tile, which is what the scan wants.

## Tests
`tests/lua/test_bug423_425_water.lua` (long brook: `at` / `nd` / `ext` / bank beside the nearest tile; a citizen at the far end; `drink_access.near`
and the recipe text; no_water decision `near` / `nd` / command).

## Live check
`dfllm cmd inspect what=water_sources` in a fort with a long brook: `bodies[].at` is the tile nearest to the citizens, `nd` its distance; a fort with the
brook in a gully: DECISION `no_water` has `near` and the `bp.sites cistern --near` command with that tile.
