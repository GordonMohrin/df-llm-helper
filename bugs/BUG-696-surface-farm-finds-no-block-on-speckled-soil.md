# BUG-696 `bp sites farms surface=1`: 2836 soil tiles and 'no plot block fits', the 5x7 plot was the smallest the template knew
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Wallfree y431-y433 (pop 49 -> 21, 28 starved or dehydrated in ~2 game years; `bp.place farms surface=1 plots=1` refused 'surface=1: 2836 soil and 0 mud floor tiles, but no plot block fits'; `bp sites farms --near` four times 'no valid site')
Module: `dfpilot/bp/rooms.py` (`farms`, `PLOT_SIZES`), `dfpilot/bp/sites.py` (`_surface_farms`, `farm_ground_why`), `dfpilot/cmd.py` (`place`, `smaller_plots`, `smaller_plots_sites`), `dfpilot/plan.py` (`farm_site`, `farm_site_plots`), `dfpilot/cli.py`

## Actual
The newest sites snapshot of Wallfree (c1a1c7f51723a745c9, z148, 80 x 73 tiles) has 2836 soil marks, all on one level, and every one of them lies in a speckled field: a soil tile, a floor tile with no soil mark, a soil tile ... `sites._surface_farms` (surface farms, BUG-297 / BUG-407) wants a whole 5x7 block (35 tiles) of soil floor under the plot, so all 11,344 (anchor, rotation) blocks failed on the first non-soil tile. The largest solid rectangle in the snapshot is 6x4 (118 places for a 3x3 plot, 6 for a 5x4). The refusal text said 'the blocks overlap the fort's own tiles, a wall, a tree or water, or lie on another walk group' (four guesses, no count); `place` fell back to fewer plots (BUG-316) down to plots=1 and then stopped, so one plot of 35 tiles was the smallest farm any command could ask for. Without a plot no crop and no brewable plant grew (drink 0 d: 'no brewable plants (199 seeds fit no farm plot)'), the kernel asked for 'farms x4' every ~35 days (58 times) and every placement failed.

## Root cause
`rooms.farms` (rooms.py:410) knew one plot size, 5 x 7. `sites._surface_farms` (sites.py, the block loop) cuts a block on the first tile that is no soil / mud floor and counts nothing; `cmd.place` ended its ladder at plots=1.

## Fix
- `rooms.farms`: new param `size` (0..4, `PLOT_SIZES` = 5x7, 5x4, 4x4, 3x3, 2x2) for a surface farm (a dug farm room keeps its 5x7 plots: `size` without `surface` is refused); the block width and height follow the size.
- `cmd.smaller_plots` / `cmd.smaller_plots_sites`: the (size, plots) overrides below the asked plot size, the largest total area first; `cmd.place` tries them after fewer plots (BUG-316) and says what it placed in `PLACE_NOTES` ('BUG-696: ... placed 2 plot(s) of 3x3 (p.size=3)'); `bp sites farms surface=1` prints the smaller size that has a site; `plan.farm_site_plots` / `plan.farm_site` count them, so the famine decision keeps the farm command and `plan propose` drafts the farm instead of waiving it.
- `sites.farm_ground_why(snap, manifest, params)`: the refusal counts the blocks looked at per first cutting condition (a floor tile that is no soil or mud, the fort's own tiles, water beside mud, another walk group) and names the smallest size that does fit with its command.

## Tests
`tests/test_bug696_f45_farm_size.py` (9: the template sizes and layout, a speckled snapshot of the live shape (no 5x7 / 5x4 / 4x4, 3x3 fits), the counted refusal, the fort's own tiles, the ladder order, `place` falls back and says so, a chessboard with no fit names both ladders, `farm_site` / `workable_food_cmds` keep the farm command), the regenerated farms goldens (`tests/bp/golden/farms.json` / `.txt`: `size` 0 in the params).

## Live check
`dfllm bp sites farms surface=1` on Wallfree's snapshot: 'no free site ... BUG-696: smaller plots fit, size=1 plots=2' (offline run on the live snapshot: 'no 5x7 plot block fits (11344 blocks looked at: 11344 hold a floor tile that is no soil or mud (speckled ground)); a 5x4 plot fits in 6 place(s)'). `bp.place tpl=farms site=S1 p.surface=1` places plots of the size that fits. Check that quickfort builds a farm plot on every tile of a 3x3 / 5x4 block (the soil mark is the snapshot's reading of the tile type, not a quickfort dry run).
Open: why the soil is speckled (the non-soil floor tiles are probably pebbles / boulders / stone floor on a soil layer, from the tile classes of `snapshot.lua`) is not read offline; a plot needs every tile soil, so a speckle denser than one tile in three cuts even a 3x3 block (the chessboard test); `economy.food.plot_tiles` (35) still sizes the number of plots asked for, so a fort on 3x3 plots asks again every 7 days until the tiles cover the need (BUG-697).
