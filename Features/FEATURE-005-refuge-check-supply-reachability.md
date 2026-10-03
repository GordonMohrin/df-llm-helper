# FEATURE-005: `refuge check` - alarm burrow must contain reachable water, drink, food and hospital

- **Status:** implemented in 59511e5
- **Priority:** P1 (more than 10 citizens died of thirst in the alarm burrow, see BUG-423)
- **Requested by:** Gordon (player), 2026-10-03, via the local orchestrator
- **Area:** `claude/mil refuge`, `lua/claude/gefahr.lua` selftest, `digest`; related: BUG-423, FEATURE-003, FEATURE-004

## Problem
After the invasion J125 the alarm burrow "Zuflucht" had no supply; citizens died of thirst. It was solved by hand: the burrow was extended with the well (139,99..140,99,z129), the drink store (117..121,88..92,z132), the food store (109..113,108..114,z130) and the connecting paths (script idea: BFS from the hospital to the storage targets, add all tiles on the path to the burrow).

## Proposed behaviour
1. `refuge check [--json]` (read-only): verify that the burrow contains a reachable well or water tile, non-forbidden drinks, non-forbidden food and the hospital zone. Output per category OK/MISSING with coordinates.
2. `refuge repair [--apply]`: BFS from the hospital to the nearest water/drink/food targets, add the path tiles and target rects to the burrow; dry-run lists the tiles.
3. Automation (`watchdog`/`gefahr`) must not switch the civilian alert on while `refuge check` fails (warning wake only), see BUG-423.

## Safety / fair play
Normal burrow edits, no item manipulation, dry-run default.

## Acceptance (fixture based)
Burrow without water -> `MISSING water`; with well tile + drink barrels + food stockpile + hospital -> OK; `repair` dry-run output contains the BFS path tiles.

## Info needed
Raw burrow tile list and the map layers around the hospital and stores (coordinates above) to test the BFS on a recorded map.

## Implementation
- **Python** `df_llm_helper/features/refuge.py`: `python -m df_llm_helper refuge check [--json] [--burrow NAME]` (read
  only) and `refuge repair [--apply]`. Check: `claude/pilot_refuge info` + `claude/pilot_reach dump` of the burrow box
  (z slabs, `refuge.slab_tiles`, cap `refuge.max_tiles`); anchor = hospital zone in the burrow, else
  `config.ZUFLUCHT.probe`, else the largest walkable part of the burrow; BFS from the anchor over burrow tiles only.
  Categories `water` (well/water tile, reached from a neighbour), `drink`, `food`, `hospital`: OK / UNREACHABLE / MISSING
  with coordinates (MISSING names the nearest target outside). Exit 0 OK, 1 not OK, 2 not readable.
- **Repair** (item 2): multi-source BFS from the refuge core (the tiles reached from the anchor; without a usable burrow
  from the hospital zone, "BFS from the hospital") over all walkable tiles, hospital first, then water, drink, food;
  adds the path tiles plus the target rect (stockpile <= `max_rect_tiles`, well + its ring, hospital zone). Dry run lists
  every new tile as row runs; `--apply` sends `claude/pilot_refuge add --apply` in chunks (UI: paint the burrow).
- **Lua**: new `lua/pilot_refuge.lua` (`info`: burrow runs, targets inside/outside with stockpile rects, only revealed
  tiles; `add [--apply]`: assign tiles, dry run by default, hidden/off-map skipped). `gefahr.refuge_supply()` now
  judges reachability with `canWalkBetween` from the anchor (`status`, `where`, `anchor`, `anchor_kind`); supplies in the
  burrow that are unreachable raise `ZUFLUCHT OHNE WASSER/ESSEN ... nicht erreichbar`. `claude/mil refuge check` adds
  `lines` (`water OK (139,99,z129)` ...).
- **Automation** (item 3): `gefahr.civ_gate` (watchdog and `gefahr.handle`) refuses the civilian alert while the refuge
  has no *reachable* drink or water when `config.REFUGE_REQUIRE_WATER = true` (warning `notfall.flag` -> wake only). The
  default stays `false`, the player decision recorded in BUG-423 ("enemies kill faster than thirst"); flip it in
  `config.lua` to enforce item 3 strictly. Not done: the Python BFS result does not feed the Lua gate (the gate uses the
  walk-group test, which does not confine the path to the burrow).
- **Digest/wake**: the `check` hook runs the check every `refuge.interval_s` (900 s) and prints one line while not OK; no
  reachable water and drink = critical warning (wake `WAKE df-llm-helper: Refuge ...`). The digest line "Refuge burrow
  not ok" names the first problem from `claude/gefahr status` and points to `refuge check`.
- **Tests**: `tests/test_refuge.py` (fixture `fixtures/v3/grid/refuge_j125.grid`: hospital-only burrow -> `MISSING water`;
  well + stores + paths -> OK; store in the burrow without a path -> UNREACHABLE; repair dry run contains the BFS path
  tiles and makes every category OK; live flow with a MockClient; Lua mock tests for `pilot_refuge info/add`, the
  reachability in `mil refuge check` and the watchdog gate).

### Live check (after `python -m df_llm_helper install-lua --apply`)
1. `claude/pilot_refuge info` - `tile_count` and `bbox` match the burrow in the UI; targets list the well
   (139,99,z129), the drink store (117..121,88..92,z132) and the food store (109..113,108..114,z130) with `in_burrow`.
2. `python -m df_llm_helper refuge check` - every category OK after the manual J125 extension; the anchor is the hospital.
   Remove a corridor tile from the burrow in the UI: the store behind it must turn UNREACHABLE.
3. `claude/mil refuge check` - `refuge.status`/`lines` agree with step 2 (walk-group test).
4. On a copy of the save, a fresh burrow with only the hospital: `refuge repair` (dry run) - the listed path follows the
   real corridors; `refuge repair --apply`, then `refuge check` -> OK; compare the painted tiles in the burrow UI.
5. Timing: `refuge check` on the full burrow box (dump size) - note the seconds; raise `refuge.interval_s` if it stalls.
