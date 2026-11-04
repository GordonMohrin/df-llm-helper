# BUG-410 embark: no whole-world pre-rank, players scan blind at ~25 s per site
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16a/16b/16c/16d (`runs/run-16*/FR-BUGS.md`: ~25-45 candidates scanned by hand per fort, most failed dark_fortress,
stone or aquifer), main 503bb8b
Module: `tools/embark/embark.py`, `tools/embark/steps.lua`, `tools/embark/checklist.lua`

## Actual
The only way to find an embark site is `scan` per candidate (a hover scan hovers 16 tiles, ~25 s). 16a: "Alle gescannten SO-Orte (ca. 25) failen
dark_fortress ...; Wunsch: Weltkarten-Scan der ganzen Welt vorab (Ranking)". 16c: ~45 candidates, 14:55-15:25. Candidates were picked
by eye from the world map.

## Root cause
A missing tool, not a defect in one line: `embark.py` has `scan` (one deep read per site) and nothing that reads the whole map cheaply.
The world map screen itself shows no text per tile (capture `world.txt`: only the two help lines), and `tools/embark/README.md` section 1
forbids world data (`world_data`, `region_map`, `embark-assistant`, finder parameters). What the vanilla UI shows is the site panel of a
hovered tile in the local view (biome, soil, aquifer, rivers, surroundings, Neighbors).

## Fix
`embark.py rank --box X0,Y0,X1,Y1 [--step N] [--sample 1|4|9] [--top N]`: one run (one `dfhack-run` call) = a hover scan with a SWEEP: per
world tile `goto`, `Embark`, 1/4/9 hovered tiles (default 4: the corners of the 4x4, spread so a brook line is more likely met), one
record. Fair play unchanged: only the panels the vanilla UI shows, mouse hold and camera as for `scan --hover`; no world data.
- `steps.lua`: `spec.sweep` (1|4|9) selects `SWEEP_OFFSETS`; a sweep row is compact (`sweep`, verdict, score, fails, warns, a few `rec`
  fields incl. the goblin distance; no items, no parts) because status.json is rewritten after every step. `checklist.evaluate` with
  `ctx.sweep`: a missing brook is a `warn` (the other tiles were not read), the size counts as 4x4.
- `embark.py`: `rank_lines` = counts per verdict, the failed criteria counted, the best N (verdict, fewest fails, fewest unknown, score)
  and the ready `scan ... --hover` line for them; at most 400 world tiles per run (`--step`, or several boxes); the wait timeout scales
  with the number of tiles; `rank --last [--top N]` ranks the newest finished sweep again without DF. Sweep rows never feed `embark --here`.

## Open
- The cost per tile (about 5 s + 1.5 s per hovered tile) is a guess; first live run decides box sizes. The world size is not read (no
  world data): the box is given by the player.
- A sweep samples 4 of 16 tiles: its `ok` is a pre-rank, the deep `scan` and the popup of the placed rectangle decide.
- The dark fortress evidence is the Neighbors section of the sampled tile (`goblin_min_rank`), as in `scan`.

## Tests
tests/lua/test_embark_fix22.lua (step lists for 1/4/9, compact row, water warn), tests/test_bug409_411_embark.py (spec, box, ranking,
`rank` command, `--last`, `prior_rows` skip).

## Live check
Window big enough for the hover scan (see BUG-247/250): `embark.py rank --box 14,18,20,24 --sample 4 --top 6` on region1; look at the time
per tile, then `embark.py scan <the printed tiles> --hover`.
