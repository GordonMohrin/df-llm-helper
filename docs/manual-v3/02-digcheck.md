# Dig safety checker: `python -m df_llm_helper digcheck` / `python -m df_llm_helper dig check` (spec v3-02)

Status: implemented, **not yet live-tested**. Read only: it never designates anything.

Run it before every dig stage. Findings mean: do not designate this stage (or use `--strip`).

## Commands
| Command | What it does |
|---|---|
| `python -m df_llm_helper digcheck Z X1 Y1 X2 Y2 [MODE]` | check a rectangle (like `claude/dig`) |
| `python -m df_llm_helper digcheck --csv FILE -c X,Y,Z` | check a quickfort `#dig` CSV at the cursor |
| `python -m df_llm_helper digcheck --stages lua/claude/stages.lua --stage N11` | check a stage (literal `add(...)` lines) |
| `... --strip` | additionally print the dig orders without the rows that hold a finding/unrevealed tile |
| `... --gamelog FILE` | count `Inappropriate dig square` cancels |
| `python -m df_llm_helper dig check ...` | alias |
| `--grid FILE` | offline on a grid fixture |

Exit codes: 0 ok, 1 unsafe (only unrevealed/uncertain tiles), 2 refused (findings or not readable).

## Rules
| Rule | Finding when |
|---|---|
| R1 | `z < z_min` (104) or `z > z_max` |
| R2 | an outside tile/sky lies within the roof/wall thickness (1; 2 at `z >= surface_z` 130) - except at allowed accesses (perimeter allow-list) |
| R3 | water or magma in the 26-neighborhood (diagonal and z+-1 included) or an aquifer wall |
| R4 | target inside `digcheck.forbid_boxes` or `water.forbid_dig` |
| R5 | a configured `cavern_boxes` box within 2, or >= `cavern_void_min` revealed underground open-space tiles within 2 |
| R6 | designation on an undiggable tile (already dug, construction, liquid) or a group of targets without any walkable neighbor |
Unrevealed targets are **reported, never judged** (`unrevealed (not judged): n tiles`); revealed targets with an
unrevealed direct neighbor are "uncertain". Both make the result `unsafe`.

## Example
```
digcheck rect 131 100 70 122 77: refused (184 tiles, R2 x46)
R2 outside contact within 2: x100..122 y70..71 z131 (46 tiles), e.g. outside tile (98,68,z131)
--strip: 6 dig orders without the problematic rows:
claude/dig 131 100 72 122 72
```

## Performance
Targets are fetched in blocks of `block` (500) via `claude/pilot_digcheck dump` (box + margin 2, max 20000 tiles per
call) with `pause_s` (0.2 s) between blocks; more than `max_cells` (3000) targets are refused ("split the stage").

## Configuration (`digcheck:`)
`z_min` 104, `z_max` 140, `roof_min` 1, `roof_min_surface` 2, `surface_z` 130, `forbid_boxes` [], `use_water_boxes`
true, `cavern_boxes` [], `cavern_void_min` 8, `max_cells` 3000, `block` 500, `pause_s` 0.2, `in_check` true.

## In `python -m df_llm_helper check`
After a refused/unsafe check one summary line is shown once. Every check is logged (`source=digcheck`).

## Fair play / lint
Only revealed tiles are classified; no cavern/region feature data is read (lint L28), caverns are recognised from
revealed open space and configured boxes. `lua/pilot_digcheck.lua` is lint-clean (no LINT-FINDINGS entry needed).

## Open live checks
Tile classification against DF 53.x (shapes, `water_table`, construction material), dump speed per block,
wiring into `raster`/`stages.lua` (call before designating) and into the agent briefing.
