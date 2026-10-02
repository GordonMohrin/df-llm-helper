# FEATURE-005: `refuge check` - alarm burrow must contain reachable water, drink, food and hospital

- **Status:** proposed
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
