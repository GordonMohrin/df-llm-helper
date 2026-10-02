# Spec v3-01: Access watcher (`dfpilot perimeter`)

Priority: P0 | As of: 01.10.2026 (run 5, Windrings, J109) | Status: **implemented (v3), not yet live-tested** (`dfpilot/features/perimeter.py`, `lua/pilot_perimeter.lua`, manual `../manual-v3/01-perimeter.md`); prototype: Lua `lua/claude/zugaenge.lua`, watcher `dfpilot/tools/zugang_watch.py` (private repo) | Framework: see `../specs-v2/README.md`

## Answer to the question "should dfpilot take this over?"
**Yes.** It is pure maintenance and monitoring (read only), it repeats permanently and it prevented real damage in run 5. The player's order: "close everything except the trap path, keep an eye on whether new openings appear". A standing order belongs in the watcher, not in my head or an ad-hoc monitor.

## Goal and benefit
Keep all entries from outside into the core known; report unauthorized new openings immediately and propose walling them up. In run 5 dig programs created two holes (north opening of the new farm hall on z131, 23 tiles; stub stair (96,88)), through which several armies came in past the traps. Without a check this is only noticed at the next attack.
**Expected gain:** no unnoticed gates; about 15-25 diagnosis calls saved per incident; prerequisite for the killbox (spec v3-08).

## Procedure (from the prototype)
1. **Path search** (`pilot_perimeter.lua`, live-untested against edge cases): multi-source breadth-first search over walkable tiles (floor, ramps, stairs; z connection via stairs/ramps). Start set: walkable tiles with `designation.outside`. Entry = first walkable inside tile. Entries are bundled into clusters (neighborhood +-2, z+-1).
2. **Core relation:** per cluster, whether an inside route leads to the core point (config) (`leads_to_core`), and whether it bypasses the trap tiles (`bypasses_traps`).
3. **Allow-list** `tools/zugang-erlaubt.txt` (coordinates, tolerance +-4/+-2): only the trap path is allowed (stair T1 (99,94,z132)). Everything else with `leads_to_core=true` is a **finding**.
4. **Message** per change, not per run: `WAKE perimeter: forbidden access to the core at (x,y,z) n tiles -> seal`; all-clear as soon as it is closed.
5. **Proposal for closing:** Quickfort grid `Cw` on the entry tiles (for stairs: the adjacent floor tiles on the inside, not the stair itself, because stairs cannot be built on). `dfpilot perimeter seal --dry-run` creates the CSV, `--apply` runs it via Quickfort (build orders, fair play).
6. **Cadence:** the search occupies the main thread about 10 s. Therefore every 20 min (configurable), not in the watcher tick, only while the game runs and there is no alarm; additionally after every dig stage (hook from `raster`) and before every Quickfort dig (spec v3-02).

## Configuration
`perimeter: {core: [100,101,130], interval_s: 1200, allow_file: tools/zugang-erlaubt.txt, tolerance_xy: 4, tolerance_z: 2, z_range: [100,136]}`
(implemented: `allow_file` is relative to `paths.tools` (default `zugang-erlaubt.txt`); additionally `cluster_xy`, `cluster_z`, `chunked`, `budget`, `poll_s`, `timeout_s`, `blueprint`, `blueprints_dir`, `in_check`)

## Fair play
Read only; walling up via normal build orders.

## Acceptance criteria
1. Test on a tile fixture (run 5, J109 before sealing): reports 3 accesses, 2 of them forbidden; after fixture "sealed" it reports only (99,94).
2. Clustering reproduces the 23 tiles of the north opening as ONE finding.
3. Stairs case: access via a stair produces a wall proposal on inside tiles, no build order on the stair.
4. Allow-list tolerance: a shift by 3 tiles stays allowed, by 6 not.
5. Runtime of the Lua search on the run-5 map <= 15 s, message only on change (test: 2 runs without change = 0 lines).
6. Digest line `Accesses: 1 allowed, 0 forbidden (checked 20:05)`.

## Fixtures/tests
Tile excerpts (type, outside flag) around the north opening and the stub stair, trap list, outputs of `claude/zugaenge` before/after sealing.

## Implementation notes (v3)
- Tests: `tests/test_perimeter.py` (all criteria; Lua scan == Python reference on the grid mock, sync and chunked). Fixtures `fixtures/v3/grid/perimeter_j109_open.grid` / `_sealed.grid` are **synthetic** (rebuilt from the run notes; T1, stub stair, 23-tile north row and the core are real, hall extent/corridors/trap tiles assumed). Real `claude/zugaenge` outputs are a fixture gap.
- Entry definition is order-independent: a reached inside tile with a reached outside tile as move neighbor. Instead of one BFS per cluster the Lua script runs two inside-only BFS from the core (with/without traps) and flags every entry; Python clusters and aggregates.
- **Non-blocking:** `pilot_perimeter start` works in chunks (`budget` nodes per frame via `dfhack.timeout`) and writes `<dfpilot home>/tools/out/perimeter_scan.json`; `dfpilot check` starts a scan every `interval_s` and evaluates it on a later check (never the synchronous `scan`). AC 5 (<= 15 s on the real map) is an open live check.
- Seal: stairs and ramps get walls on their adjacent inside floor tiles; door/trap tiles are left to the player. `--apply` always runs `reach what-if` first and refuses if a mandatory point would be cut (or the check cannot prove safety) unless `--override "<reason>"` is given; the CSV goes to `<blueprints_dir>/claude/dfpilot_seal.csv` and `quickfort run claude/dfpilot_seal.csv -c x,y,z` is executed.
- Not done here (other files): hook from `raster` after each dig stage.
