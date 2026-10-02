# Spec v3-08: Defense designer (`dfpilot defense design|status|stats`)

Priority: P1 | As of: 01.10.2026 (Run 5, year 109) | Status: implemented (v3), not yet live-tested | Framework: see `../specs-v2/README.md`
Implementation: `dfpilot/planners/defense.py` (pure design), `dfpilot/features/defense.py` (CLI), `lua/pilot_defense.lua`
(read-only status, LIVE-UNTESTED), tests `tests/test_defense.py`, synthetic fixtures `fixtures/v3/defense/`, manual
`../manual-v3/08-defense.md`.

## Goal and benefit
Generate a funnel/killbox design automatically from terrain and access data (spec v3-01) and monitor trap reloading.
In Run 5, the player (wish: "a big trap box in front of the entrance") and the build agent had to plan the lane, walls,
traps and shooter niches by hand; the existing 19 stone traps lay next to a free lane and almost never triggered.
**Expected gain:** reproducible, checked defense structures; about 20-30 calls of design and checking work saved;
attacks (6 sieges on 01.10.) end with fewer wounds.

## Inputs
Tile cut-out around the entrance (e.g. plateau z133 x93..105,y88..111), access list (v3-01), stock (mechanisms, trap
components, stones, iron/steel), core and barracks position.

## Design (deterministic, planner)
1. **Lane:** 1 tile wide, length L (default >= 20), constructed walls (`Cw`) on both sides; connected to the
   door/stair so that `claude/zugaenge` reports only the access (99,94) and the path to the door leads **exclusively**
   through the lane (path search with/without lane as a test).
2. **Occupation:** one trap per lane tile: stone-fall traps (`Ts`) on the first part, weapon traps (`Tw`, giant
   serrated discs/spiked balls) in the last third, cage traps (`Tc`) as a reserve; number of traps and component
   demand calculated.
3. **Shooters:** niche behind the lane wall with fortifications (arrow slits), weapon/armor stands, crossbow/bow posts
   (squad "shooters").
4. **Citizen/merchant paths:** a separate safe path (depot (112,98,z133)) or a note that merchants walk through the lane.
5. **Output:** quickfort grid (`#build`, zones, cursor), material list (mechanisms, stones, iron/steel for N weapon
   traps), order of stages, ASCII sketch.
6. **Reloading:** `dfpilot defense status`: number of loaded/triggered stone traps (open `Load stone trap` jobs), trap
   parts in stock; warning below 70 % loaded; suggest a stone stockpile near the lane.
7. **Effectiveness:** statistics after each attack: enemies in the lane, killed by traps (gamelog: "trap"), wounds of
   the guard; adjustment suggestions.

## Configuration
`defense: {lane_len: 20, wall: Cw, trap_mix: {Ts: 0.6, Tw: 0.3, Tc: 0.1}, shooter_niche: true, reload_warn_pct: 70}`
Implementation adds: `components_per_weapon_trap: 1`, `bars_per_component: 3` (assumption), `blueprint_dir: ""`
(target folder for `--apply`, e.g. `.../dfhack-config/blueprints/claude`), `blueprint_name: defense`, `in_check: false`.

## Fair play
Only build orders, zones, quickfort with our own grids, orders for trap parts (forge).

## Acceptance criteria
1. On Run-5 terrain (fixture): design with lane >= 20, path search shows the lane as the only path (test).
2. Material demand matches the number of traps (mechanisms = traps).
3. The quickfort grid passes the blueprint validator (`plan blueprint`).
4. `defense status` detects "12 of 20 stone traps empty" in the fixture and warns.
5. Loop protection: the design is built only on an explicit call (no automatic build).

## Fixtures/tests
Terrain cut-out z133, trap coordinates (19 stone traps, 15 in gatehouse B), gamelog "Load stone trap".

## Implementation notes (v3)
- Command: a new top-level command `dfpilot defense ...` (feature plug-in) instead of `plan defense`, because `plan`
  lives in `cli.py`. Acceptance mapping: 1 `test_lane_length_and_only_path` (independent BFS in the test), 2
  `test_materials_match_traps`, 3 `test_csv_passes_blueprint_validator`, 4 `test_status_12_of_20_empty_warns` /
  `test_status_cli`, 5 `test_design_cli_never_builds` / `test_apply_plan_requires_confirm`.
- Lane search: DFS from the door (straight runs first, then the turn with the longer free run, fixed N/E/S/W
  tie-break), 8-neighborhood path model (DF diagonal steps); lane tiles may touch only their two predecessors; walls on
  every floor neighbor of door + lane except the mouth tile; ramps/stairs/old traps next to the lane are rejected
  (they would be holes). Corner tiles can be skipped diagonally (one trap less on that path).
- Trap order from mouth to door: Ts, Tw, Tc (cage traps as the last line right in front of the door).
- Shooter niche: 3x2 tiles behind a straight lane segment (closest to the lane middle), the shared wall row becomes
  `CF`, rack `r` and stand `a` in the back row, enclosed by `Cw`; access only from below (stair from z-1 by hand).
- CSV: three `#build label(walls|traps|niche)` sections on one bounding box, cursor = its top-left corner;
  `--apply --confirm` runs `quickfort run claude/<name>.csv -n /<label> -c x,y,z` per stage.
- Citizens/merchants: the plan only notes that the door is reachable through the lane; a separate depot path is not
  designed (depot (112,98) is outside the cut-out).
- Not implemented: zones/archery range in the CSV, consuming the v3-01 access list directly (the terrain file carries
  door + access), wounds of the guard in `stats`, `check` hook (status needs a DF call).
- Open live checks: real z133 tiles (the fixture is synthetic), how DF 53.16 exposes "loaded" for stone-fall traps
  (`pilot_defense.lua` uses a boulder among contained items / an open load job as heuristic and reports raw
  `state`/`ready_timeout`), job type/name of the load job, gamelog trap message texts, quickfort keys `CF`/`r`/`a`
  and `-n /label`, bars per trap component.
