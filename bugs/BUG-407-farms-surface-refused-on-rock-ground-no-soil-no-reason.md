# BUG-407 'bp.place farms surface=1' refused 'only 0 free site(s)' on rock/mountain ground: no reason, no alternative
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Bachwald R3, `runs/run-16a/FR-BUGS.md`), main 503bb8b
Module: `dfpilot/bp/sites.py`, `lua/dfllm/snapshot.lua`

## Actual
i1: DECISION_NEEDED thirst/stranded_drink offered `bp.place farms surface=1` -> `refused: only 0 free site(s) for farms surface=1`
(mountain, no strip of soil); the same in the other forts without a fortcore (16c: 'no fortcore project placed'). 13 citizens died of
thirst with 50 seeds in stock.

## Root cause
`sites._surface_farms` (sites.py:930 before): (1) a plot block counted only inside a Z4 box or within `SURFACE_NEAR` (12) tiles of the
fort's entrance (manifest `edge`): a fort without a dug core has neither, so even a meadow gave 0; (2) only `marks.soil` was ground,
although quickfort builds farm plots on soil OR on a floor with mud (`build.lua is_valid_tile_farm`: `has_mud`); (3) `rank` returned
`[]` and `cmd.place` printed only 'only 0 free site(s)' (`farm_hint` is skipped for surface=1), and `rank` demanded `zones.Z4` first.

## Fix
- `sites._surface_farms`: ground = soil marks + `marks.mud`; a muddy block must keep `MUD_WET_R` (3) tiles from water (irrigation is risky,
  never offered); when no block lies inside Z4 or near the entrance, the soil/mud anywhere on the citizens' walk group is offered (score
  `FAR_SCORE` 500 minus the tiles to the entrance, depot or middle of the snapshot); `rank` needs no manifest for `farms surface=1`.
- `sites.farm_ground_why` (appended by `cmd.farm_hint` to the 'only 0 free site(s)' refusal of a surface farm): no ground -> 'no soil and no mud floor in this snapshot (N revealed floor tiles ...); DECISION: buy
  food and seeds (trade.want food seeds), dig down to a soil layer (explore) or wait for rain to mud a floor ... irrigation is risky';
  ground but no block -> 'DECISION: fewer plots, another spot (--near) or trade'. `RANK_V` 6.
- `snapshot.lua` `M.has_mud`: a sites export marks muddy floors `marks.mud` (a solid MUD spatter of the map block with an amount on the
  tile, read once per block and export; audit exports do not look). Schema: `snapshot.marks.mud` (<= 8000), appendix rewritten.
- `render`: mud counts as plot ground (no 'not known as soil' warning).

## Open
A farm on a dug floor that was muddied later is found only when the export sees the mud (rain, flood); no irrigation is planned.

## Tests
tests/test_bug406_408_farm_ground.py (9), tests/lua/test_snapshot_mud.lua (2). Fail on 503bb8b.

## Live check
`bp sites farms surface=1 --fresh` in a fort with no fortcore on a map with soil: sites ranked with 'middle of the snapshot'; on bare rock:
the refusal names 'no soil and no mud floor' and the DECISION; after rain `snapshot.marks.mud` is non-empty on rock floors.
