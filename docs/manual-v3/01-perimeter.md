# Access watcher: `dfpilot perimeter` (spec v3-01)

Status: implemented, **not yet live-tested**. Read only, except `seal --apply` (normal build orders).

Keeps every entry from outside into the core known. Only the allowed ones (the trap path, allow-list) may lead to the
core; every other access to the core is a finding and gets a wall proposal.

## Commands
| Command | What it does |
|---|---|
| `python -m dfpilot perimeter` (`scan`) | start the chunked Lua scan, wait for the result, evaluate; exit 1 = forbidden access |
| `python -m dfpilot perimeter status` | last stored result (no DF call) |
| `python -m dfpilot perimeter seal` | write the Quickfort CSV (`tools/out/perimeter_seal.csv`) with `Cw` walls - dry run |
| `python -m dfpilot perimeter seal --apply [--override "<reason>"]` | `reach what-if` first, then `quickfort run claude/dfpilot_seal.csv -c x,y,z` |
| `python -m dfpilot perimeter allow [X Y Z --note TEXT]` | show / extend the allow-list |
| `--grid fixtures/v3/grid/perimeter_j109_open.grid` | offline on a grid fixture (`@core`, `@allow` lines) |

## Output
```
WAKE perimeter: forbidden access to the core at (111,70,z131) 23 tiles -> seal (dfpilot perimeter seal --dry-run)
Accesses: 1 allowed, 2 forbidden (checked 20:05)
  FORBIDDEN: (111,70,z131) 23 tiles, bypasses the traps
  allowed: (99,94,z132) 1 tile, through the traps
```
WAKE lines only on a **change** (new forbidden access; "all forbidden accesses closed" when the last one is gone).
Two scans without a change print no WAKE line. New forbidden accesses raise a critical warning (`perimeter:forbidden`).

## Allow-list
`<paths.tools>/zugang-erlaubt.txt`, one `x,y,z  comment` per line, e.g. `99,94,132  trap stair T1`. An access is
allowed when its cluster center lies within +-4 x/y and +-2 z of an entry (shift by 3 = allowed, by 6 = not).

## Seal rules
- Wall (`Cw`) on every entry tile of a forbidden cluster.
- Stairs and ramps cannot carry a construction: the walls go on the adjacent **inside floor** tiles of the same level.
- Door/trap tiles are left to the player (note in the output).
- `--apply` never cuts a mandatory reach point: `reach what-if` runs first; if it warns (or cannot prove safety) the
  seal is refused unless `--override "<the player's yes>"`. The CSV is copied to
  `<perimeter.blueprints_dir or <DF>/dfhack-config/blueprints>/claude/dfpilot_seal.csv`.

## Configuration (`perimeter:`)
`core` ([100,101,130]), `interval_s` (1200), `allow_file` (zugang-erlaubt.txt, relative to paths.tools),
`tolerance_xy` (4), `tolerance_z` (2), `z_range` ([100,136]), `cluster_xy` (2), `cluster_z` (1), `chunked` (true),
`budget` (20000 nodes per frame), `poll_s` (2), `timeout_s` (120), `blueprint` (claude/dfpilot_seal.csv),
`blueprints_dir` (null = derived from dfhack_run), `in_check` (true).

## In `dfpilot check`
Never blocks: every `interval_s` (game running, no alert/siege flag) it starts `claude/pilot_perimeter start ...`
(chunked over many frames, result file `<dfpilot home>/tools/out/perimeter_scan.json`); a later check fetches
`claude/pilot_perimeter result` and evaluates. Lines only on a change (WAKE lines + digest line).
Actions are logged (`source=perimeter`: `scan`, `seal-plan`, `seal`, `seal-refused`, `allow`).

## Lua: `claude/pilot_perimeter`
`scan cx cy cz zmin zmax [budget]` (synchronous - blocks DF, only by hand), `start ...` (chunked), `result`.
Output: `entries` = `[x,y,z,core,notrap]` per entry tile; Python clusters (+-2 xy, +-1 z).

## Open live checks
Runtime on the real map (spec: <= 15 s total, chunked per frame), `dfhack.timeout` while paused, trap detection via
`dfhack.buildings.findAtTile`, quickfort run of the generated CSV, hook after each `raster` dig stage (not wired).
