# BUG-424 no safe access to water that lies behind rock close to the fort
Status: fixed (offline, live-untested); open: the live shape of a gully intake (see Open)
Severity: high
Found: 2026-11-05, Run 16a i1 Manorsubtle (also Mansionlauded, Bachwald: three forts in a row died of thirst), main 03f4c1a
Module: `dfpilot/bp/sites.py` (`_rock_top_ok`, `intake_ok`, `_intake_targets`, `plan_cistern`, `cistern_access`), `lua/dfllm/economy.lua` (`M.no_water`),
`dfpilot/wake.py` (`_request_access`, `_place`), `dfpilot/plan.py` (`request_facts`, `water_access`, `request_drafts`)

## Actual
The brook lay 8 tiles from the start room in a rock gully with unrevealed rock between. The cistern template could not be offered: the planner wants a
revealed bank FLOOR tile for the shaft top and the breach (`intake_ok`: "shaft top or breach tile is not revealed bank floor"), and a gully has none. The
water rule (no free digging within 3 tiles of open water) left the player with nothing; the DECISION only pointed at the command that answered "no site".
One cistern path of 5 tiles would have saved the fort.

## Root cause
`sites.py intake_ok` / `_intake_targets` accepted only '.' (floor) at the shaft top B and the breach G; water in a gully (rock '#' / unrevealed '?' beside it)
yielded no target, so `plan_cistern` raised "no revealed water with two tiles of revealed bank floor". Nothing asked for such a plan when drink ran down,
and `plan propose` drafted no cistern at all while `fill.ok` was False (no bucket-fed fill source).

## Fix
- `sites._rock_top_ok`: a SEALED ROCK INTAKE: B and G rock or unrevealed, every tile round B rock/unknown, the ring of G rock/unknown/water, rock or unknown
  right above both. The template digs them (shaft stage, breach stage) with its breaker, fortification and floodgate, as for a bank intake; nobody
  free-digs beside the water. `intake_ok` and `_intake_targets(rock=True)` use it; `plan_cistern(rock=None)` tries the bank intake first, then the rock one
  (result `rock` 1, `why` says so).
- `sites.cistern_access(snap, manifest, near, radius)`: the safe plan first (no water above the well room), else the unsafe one is returned flagged
  `unsafe` (never placed by itself); `site` = the explicit anchor label `A<x>_<y>_<z>_<rot>`.
- `economy.no_water`: with drink below `economy.drink.access_d` days (400, 0 = never) every weekly decision also emits `PROJECT_REQUEST cistern
  why=no_water` with `at` = the nearest water tile (BUG-423) and `n` its distance (schema: `PROJECT_REQUEST at:ia`).
- `wake.py`: follow takes a sites snapshot (`cistern_water` job), plans on it and places the cistern with its params at prio 1; no plan, or only an unsafe
  one: AUTO_FAIL with the reason (the unsafe text names `python -m dfpilot.bp.sites cistern --near x,y,z --unsafe` for Gordon); nothing when a cistern with a
  pipe is placed already.
- `plan.py`: `request_facts` carries the request with `access` (`water_access`), `request_drafts` drafts `cistern` with the plan's site label and params
  (the emergency front moves it up), or notes why not.
- The alternative of an access tunnel that stops >= 4 tiles short of the water was not built: the template's pipe IS that tunnel (dug as part of the template
  with its closed floodgate), and a second dig tool near water is what the rule forbids.

## Open
- Offline only: the planner reads revealed tiles; the gully intake needs rock above both tiles and a sealed ring, which a real gully may not have (open sky above
  the walls): then there is no plan, the AUTO_FAIL says so and the nearest water stays Gordon's call. Whether DF accepts a channel designation on a solid wall tile
  for the breach (`mdh` on rock) is the first live check.
- The follow snapshot is the default sites export; if the water lies outside its box the plan says "no revealed water" (the AUTO_FAIL names the water tile and
  `bp sites cistern --near`).
- Manorsubtle's well room (Z4 z150-157) lies under the brook (z158): the safe rule (water not above the well room) refuses it; the unsafe route is offered to
  Gordon, never placed by follow.

## Tests
`tests/bp/test_bug424_rock_intake.py` (gully: no bank intake, a sealed rock one; open sky above / a floor at B's ring: none; `cistern_access` safe and unsafe;
no water), `tests/test_bug423_425_access.py` (follow places / refuses an unsafe route / names the refusal / no second one; propose drafts; request_facts;
water_access), `tests/lua/test_bug423_425_water.lua` (the request).

## Live check
A fort whose only water is a brook in a gully: `events --cls A` shows `no_water` with the `cistern --near` command and `events --type PROJECT_REQUEST` the cistern
request; `cli.log` `auto:cistern_water` placed (or AUTO_FAIL with the reason); `python -m dfpilot.bp.sites cistern --near <at>` prints a plan with "sealed rock intake";
after the breach `cistern-check`, then the lever.
