# Spec v3-02: Dig safety checker (`python -m df_llm_helper dig check`)

Priority: P0 | As of: 01.10.2026 (run 5, J109) | Status: **implemented (v3), not yet live-tested** (`df_llm_helper/features/digcheck.py`, command `python -m df_llm_helper digcheck` with alias `python -m df_llm_helper dig check`, `lua/pilot_digcheck.lua`, manual `../manual-v3/02-digcheck.md`) | Framework: see `../specs-v2/README.md`

## Goal and benefit
Check dig orders **before** they are set, so that they do not open new holes to the outside, and do not tap an aquifer, water or a cavern. Causes in run 5: the farm hall on z131 broke through at the surface (north opening), the diagonal water access flooded the tunnel, stages ran into the blocked boxes. So far an agent checked this by hand each time.
**Expected gain:** avoids total losses; about 10 manual check calls saved per stage; makes large dig programs (35,000 tiles) auditable.

## Behavior
1. **Input:** list of dig rectangles/lines (`stages.lua`, `claude/dig`, Quickfort dig CSV) or a stage name.
2. **Rules per tile/block (Lua `pilot_digcheck.lua`, read only):**
   - R1 level `z >= DIG_MIN_Z` (104) and `z <= Z_MAX_DIG`.
   - R2 **outside contact:** no target tile and no neighbor (26-neighborhood) with `designation.outside` or sky/void, unless explicitly part of an allowed access (allow-list of spec v3-01); roof/wall thickness >= 1 (2 at z >= 130).
   - R3 **water:** no neighbor (incl. diagonal and z+-1) with `flow_size > 0`, no aquifer tile (`water_table`), no magma.
   - R4 **blocked boxes** from `config.yaml` (water tunnel, emergency wall, tunnel W, aquifer levels).
   - R5 **caverns:** no tile with `designation.subterranean`/cavern flag or cavern level within a range of 2.
   - R6 **reachability:** target tiles must border walkable terrain (otherwise an "Inappropriate dig square" loop; observation: 41 cancels, 29 dwarves).
3. **Output:** `ok` / finding list with stage, coordinates, rule; on a finding the stage is **not** designated (option `--strip` removes only the problematic strips).
4. **Integration:** `raster`/`stages.lua` call the checker before designating; `lint` (F9) binds it as rule `L31` for Lua scripts that contain `dig` calls; the agent briefing contains "before every stage `dig check`".
5. **Follow-up check:** after every stage run `perimeter` (v3-01) and `water` (spec v2-08) once.

## Configuration
`digcheck: {z_min: 104, roof_min: 1, roof_min_surface: 2, forbid_boxes: [...], max_cells: 3000}`
(implemented additionally: `z_max`, `surface_z` (130), `use_water_boxes` (adds `water.forbid_dig`), `cavern_boxes`, `cavern_void_min` (8), `block` (500), `pause_s` (0.2), `in_check`)

## Fair play
Read only; no map reveal (only already revealed tiles; unrevealed ones count as unsafe and are not judged).

## Acceptance criteria
1. Stage that created the north opening (z131, y70..77): `R2` reports outside contact with coordinates.
2. Diagonal access to the bank (F=(184,43,z128)): `R3` reports water diagonally.
3. Stage in a blocked box: `R4`.
4. Unreachable tiles: `R6` (fixture with "Inappropriate dig square").
5. Performance: 3000 tiles <= 3 s main thread (batching in blocks of 500, pause in between), no freeze.
6. Unrevealed tiles are reported, not judged.

## Fixtures/tests
Tile excerpts north opening and river bank (before/after), `stages.lua` stages N11-N35, gamelog "Inappropriate dig square".

## Implementation notes (v3)
- Tests: `tests/test_digcheck.py` (R1..R6 each with a positive and a negative case, unrevealed, blocks/pauses, inputs, `--strip`, CLI alias, check hook). Fixtures `fixtures/v3/grid/dig_north_opening.grid`, `dig_river_diagonal.grid`, `dig_cavern_unreachable.grid`, `gamelog_run5_cancels.txt` are **synthetic** (river tiles from LAYOUT-run5.md 11; the cavern, aquifer and unreachable cases are made up). Stage parsing is tested against the real `lua/claude/stages.lua` (N11).
- The Lua script only dumps tile characters (one call per block of <= 500 targets, box + margin 2, max 20000 tiles); all rules run in Python, so they are testable on grid fixtures.
- **Deviation R5:** no cavern/region feature data is read (lint L28). A cavern is assumed when a configured `cavern_boxes` box lies within 2, or when >= `cavern_void_min` revealed underground open-space tiles (`designation.subterranean`, shape EMPTY) lie within 2 (single channel/stair holes do not count). Conservative; atria can trigger it.
- **R6** has two parts: designation on an undiggable tile (already dug/open, construction, liquid) = "inappropriate dig square", and groups of targets without any walkable neighbor (same level; stair/channel modes also z+-1).
- R2 uses the perimeter allow-list (`perimeter.allow_file`, same tolerance) for outside tiles at allowed accesses.
- Inputs: `rect z x1 y1 x2 y2 [mode]`, `--csv FILE -c x,y,z` (quickfort `#dig`, `#>`/`#<`), `--stages FILE --stage NAME` (literal `add(...)` lines only; stages generated in loops are not visible).
- Not done here (other files): calling the checker from `raster`/`stages.lua`, lint rule binding (L31 stays the box check in `lint.py`), briefing text.
