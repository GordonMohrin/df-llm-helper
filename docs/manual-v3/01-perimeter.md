# Access watcher: `python -m df_llm_helper perimeter` (spec v3-01)

Status: implemented, **not yet live-tested**. Read only, except `seal --apply` (normal build orders).

Keeps every entry from outside into the core known. Only the allowed ones (the trap path, allow-list) may lead to the
core; every other access to the core is a finding and gets a wall proposal.

## Commands
| Command | What it does |
|---|---|
| `python -m df_llm_helper perimeter` (`scan`) | start the chunked Lua scan, wait for the result, evaluate; exit 1 = forbidden access |
| `python -m df_llm_helper perimeter status` | last stored result (no DF call) |
| `python -m df_llm_helper perimeter seal` | write the Quickfort CSV (`tools/out/perimeter_seal.csv`) with `Cw` walls - dry run |
| `python -m df_llm_helper perimeter seal --apply [--override "<reason>"]` | `reach what-if` first, then `quickfort run claude/df_llm_helper_seal.csv -c x,y,z` |
| `python -m df_llm_helper perimeter allow [X Y Z --note TEXT]` | show (with notes) / extend the allow-list; refuses tiles outside the map, warns near the core |
| `--grid fixtures/v3/grid/perimeter_j109_open.grid` | offline on a grid fixture (`@core`, `@allow` lines) |

## Output
Example from the grid fixture `perimeter_j109_open.grid` (live, the stair T1 is reported as `bypasses the traps` when
the trap tiles are not on its walking path - same result as `claude/zugaenge`):
```
WAKE perimeter: forbidden access to the core at (111,70,z131) 23 tiles -> seal (python -m df_llm_helper perimeter seal --dry-run)
Accesses: 1 allowed, 2 forbidden (checked 20:05)
  FORBIDDEN: (111,70,z131) 23 tiles, bypasses the traps
  allowed: (99,94,z132) 1 tile, through the traps
```
WAKE lines only on a **change** (new forbidden access; "all forbidden accesses closed" when the last one is gone).
Two scans without a change print no WAKE line. New forbidden accesses raise a critical warning (`perimeter:forbidden`).

## Allow-list
`<paths.tools>/zugang-erlaubt.txt`, one `x,y,z  comment` per line, e.g. `99,94,132  trap stair T1`. An access is
allowed when its cluster center lies within +-4 x/y and +-2 z of an entry (shift by 3 = allowed, by 6 = not).

## What counts as an access (live comparison 02.10.2026)
The scan uses DF's own walkability: floors, ramps, stairs; a tile with a building that blocks walking (well, statue:
occupancy `Obstacle`/`Well`) is a wall, **workshops and furnaces are walkable** (occupancy `Passable`; dwarves stand
on them). The companion script `claude/zugaenge` (live copy) treats workshops/furnaces as walls: on the run-5 map this
hides the access `(108,92,z132)`: outside ramp `(105,84,z131)` -> the kitchen workshop tile `(106,85,z132)` -> farm
terrace (flagged "outside" by DF) -> farm hall F1. If you consider a workshop a barrier, allow that access in the
allow-list; otherwise seal it (`seal --dry-run`, walls may only go on free floor, not on a farm plot). The entry tile of an
access is reported as the first inside tile (a stair top can lie one level above the allow-list line: `99,94,133` is
allowed by `99,94,132` through the z tolerance).

Movement is DF's rule (BUG-424): 8 directions, and a diagonal step between two walls that touch only at a corner
**is** possible - such a corner is a hole. `claude/pfadcheck` (the old game-folder check with a fixed box and a
stricter diagonal rule, which missed two bypasses of the trap alley) is now a front end of `pilot_perimeter scan`:
`core_reached` = "A", `bypass` = "B" (reaches the core without a trap tile), `entries` with `notrap = 1` are the bypasses.

## Seal rules
- Wall (`Cw`) on every entry tile of a forbidden cluster.
- Stairs and ramps cannot carry a construction: the walls go on the adjacent **inside floor** tiles of the same level.
- Doors/hatches are **never a seal** (BUG-424: the game resets `door_flags.forbidden`, a "locked" door let the
  enemies through): the scan always counts them as walkable, and `seal` proposes walls on the inside floor behind a
  door entry (note in the output; or deconstruct the door and wall its tile). Trap tiles are left to the player.
- A stair/ramp entry without any inside floor tile next to it gets a note "seal by hand" (no automatic proposal;
  `seal` then exits 1 instead of claiming "nothing to do").
- `--apply` never cuts a mandatory reach point: `reach what-if` runs first; if it warns (or cannot prove safety) the
  seal is refused unless `--override "<the player's yes>"`. The CSV is copied to
  `<perimeter.blueprints_dir or <DF>/dfhack-config/blueprints>/claude/df_llm_helper_seal.csv`.

## Configuration (`perimeter:`)
`core` (null = `FORT_REFS[1]` of `claude/config`, resolved by the Lua script), `interval_s` (1200), `allow_file` (zugang-erlaubt.txt, relative to paths.tools),
`tolerance_xy` (4), `tolerance_z` (2), `z_range` (null = `Z_MIN..Z_MAX` of `claude/config`), `cluster_xy` (2), `cluster_z` (1), `chunked` (true),
`budget` (20000 nodes per frame), `poll_s` (2), `timeout_s` (120), `blueprint` (claude/df_llm_helper_seal.csv),
`blueprints_dir` (null = derived from dfhack_run), `in_check` (true), `min_outside` (3000: enclave filter - an entry
counts only if its outside area has at least this many connected tiles, so walled-in terraces with the sky flag are no
access; 0 = off).

## In `python -m df_llm_helper check`
Never blocks: every `interval_s` (game running, no alert/siege flag) it starts `claude/pilot_perimeter start ...`
(chunked over many frames, result file `<df-llm-helper home>/tools/out/perimeter_scan.json`); a later check fetches
`claude/pilot_perimeter result` and evaluates. Lines only on a change (WAKE lines + digest line).
Actions are logged (`source=perimeter`: `scan`, `seal-plan`, `seal`, `seal-refused`, `allow`).

## Lua: `claude/pilot_perimeter`
`scan cx cy cz zmin zmax [budget] [min_outside]` (synchronous - blocks DF, only by hand), `start ...` (chunked), `result`.
Output: `entries` = `[x,y,z,core,notrap]` per entry tile; Python clusters (+-2 xy, +-1 z).

## Open live checks
Runtime on the real map (spec: <= 15 s total, chunked per frame), `dfhack.timeout` while paused, trap detection via
`dfhack.buildings.findAtTile`, quickfort run of the generated CSV, hook after each `raster` dig stage (not wired).
