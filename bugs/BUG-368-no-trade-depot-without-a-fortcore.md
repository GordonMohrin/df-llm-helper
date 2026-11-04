# BUG-368 no trade depot without a fortcore
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16b (i2 Ostgate, y373/y376, `runs/run-16b/FR-BUGS.md`), main 2fcd6e0
Module: `dfpilot/bp/rooms.py`, `dfpilot/bp/sites.py`, `dfpilot/bp/emit.py`, `dfpilot/plan.py`, `dfpilot/cmd.py`

## Actual
i2 (no fortcore ever stood): NO_DEPOT / DEPOT_MISSING `no known depot site (no fortcore depot): place one by hand` every
autumn, the caravan (Catten) came and could unload nothing: no trade, no metal (ore 0, METAL SHORT), no leather or yarn for
two strange moods. The report asked for a `depot` template for forts without a fortcore.

## Root cause
A trade depot existed only as `D` in the fortcore stage 1 bailey (`bp/fortcore.py:148`, manifest `depot` `fortcore.py:246`) and
as the runner's keeper project (`runner.lua depot_keep`, centre = `manifest.depot` or the last depot seen: both absent
without a fortcore, `no known depot site`). `bp.emit.TEMPLATES` had no depot template, `plan.propose` never drafted one.

## Fix
- `bp/rooms.py` `depot` (in the new `rooms.SURFACE`, merged into `emit.TEMPLATES`; not in `rooms.BUILD`: no room, nothing
  dug, no Z4, no burrow): one build stage `D(5x5)`, manifest `depot` = its middle (so the keeper rebuilds it there after a
  siege). Like the BUG-356 startup shops.
- `bp/sites.py` `_surface_shops(.., tpl="depot")`: a 5x5 block of revealed floor with open sky above on one level, on the
  citizens' walk group (BUG-352 `wg`), off the fortcore keep-out tiles, nearest the middle of the snapshot (or `--near
  <wagon>`), +60 within 25 of the entrance; no fort manifest needed (`rank` skips the Z4 requirement for `depot`).
  `cmd.no_site_hint` names the block it needs when nothing ranks.
- `plan.py`: `DEPOT`, `DEPOT_BUILD`, `depot_planned` (kernel manifest `depot`, a `depot` bp project, or a digging fortcore
  stage 1 whose bailey builds it) as fort fact `depot`; `propose` drafts `depot@S1` when it is False and the draft has no
  fortcore stage 1 (note `BUG-368`); `build_kind` = `depot` (runner kind_of: never paused by a seal, runs in the rebuild).
  `metal_facts` already counted a `depot` project as a route for the caravans' bars.

## Open
Wagons need a way from the map edge to the depot: the block only has to lie on the citizens' walk group (a site beyond a
brook is dropped), not on the wagon route; a depot in the middle of a tree stand is not offered at all (flat open floor).
The Lua side is unchanged (a placed project of tpl `depot` is what the runner's kind_of already knows).

## Tests
tests/test_bug368_370_depot_fresh_walk.py (template, sites, walk group, placing without a fortcore, propose, depot_planned),
tests/bp/test_bp_emit.py unchanged (the depot is not a room).

## Live check
i2: `bp sites depot --fresh --near <wagon x,y,z>` lists a site; `plan propose` drafts `depot@S1`; `bp.place depot site=S1`; the
depot stands within days (`status`: trade depot), the autumn caravan trades, DEPOT_MISSING stops.
