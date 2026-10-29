# BUG-303 Sand zones on floors DF does not count; the abort series went unseen (no GLASS_BLOCKED)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15d (Drillchamber, FR-BUGS Runde 2/3)
Module: `lua/dfllm/snapshot.lua` (is_sand, tile), `lua/dfllm/economy.lua` (cancel, glass_plan, glass_sand, glass_report), `lua/dfllm/zonelib.lua` (zone.place)

## Actual
Drillchamber y375: economy painted the 1x1 zone 18035 `dfllm-sand` at 70,83,144 (kern.log `glass: sand collection zone dfllm-sand at
70,83,144`, commands.log `act.sand_zone [[70,83,144]] ok`) and ordered CollectSand x2. The game then cancelled `Collect sand: Need
valid, active sand collection zone` again and again: 653 by y377, 884 when the player added the 3x3 zone 18173 at 71-73,82-84 z144
(`zone.place` ok), 1,233 in the gamelog at the end (E:/DF-test4/gamelog.txt; many different workers). No GLASS_BLOCKED and no
CANCEL_LOOP in events.jsonl; three strange moods that wanted gems or glass died or went insane.

## Root cause
1. `snapshot.lua` M.is_sand (Run 11) decided "sand" from the geology layer alone (`tile-material` GetLayerMat, SOIL_SAND), and
   the export asks it for every soil floor, where soil includes the grass materials (`SOIL_MAT` GRASS_LIGHT/DARK/DRY/DEAD, PLANT).
   A grass-grown or plant tile of a sand layer was marked sand. The snapshot of y378 lists 70,83 / 71,83 / 70,84 / 71,84 z144 as sand
   marks on the surface level z144. DF collects sand from a sand tile; a floor whose tiletype material is grass is none. The DF wiki
   (Sand, Grass) confirms it: grass growing over sand makes it unavailable for collection ("Need valid, active sand collection zone"
   for a new job, "Sand vanished" for a running one); a paved road or a floor grate over bare sand stops regrowth. The tiletype of the
   Drillchamber tiles could not be read offline.
2. `zonelib.lua` Z.verb drew a sand zone on any revealed floor (only rock, air, water and conflicts were refused).
3. `economy.lua` glass_plan: `M.sand_zones() > 0` meant "zone ok" for ever. The cancels came about one a day, below the 5-a-day
   CANCEL_LOOP; `Need valid ...` is no `Needs ...` reason, so needs_cancel never dropped the order; GLASS_BLOCKED knew only no_sand,
   no_bags, no_fuel.

## Fix
- snapshot: M.is_sand needs a bare soil floor (tiletype material SOIL, shape FLOOR) of a SOIL_SAND layer; tile() carries `sand`.
- zone.place type=sand: refused without one bare sand floor in the box; the refusal names up to 3 sand floors the exports saw that
  the tile reader still calls sand (`sand floors seen: x,y,z ...`), else `dig into a sand layer, then export`.
- economy: every `Collect sand` cancel with DF's words `sand collection zone` counts into `p.sand_bad` {n, first, last} (a gap of
  more than `glass.sand_abort_days` 7 starts a new series). From `glass.sand_abort` 3 cancels the zones count as invalid: blocker
  `sand_invalid`, GLASS_BLOCKED once per series at once (`d.aborts`), no CollectSand into them, and glass_sand paints a new zone on a
  bare sand floor outside every sand zone (the tile reader is asked again: grass may have grown since the export). A painted zone
  ends the series. The old zones are not removed (one is the player's).

## Tests
`tests/lua/test_snapshot.lua` (BUG-303 is_sand), `tests/lua/test_zone_place.lua` (BUG-303 zone.place sand),
`tests/lua/test_economy_glass.lua` (BUG-303 abort series). Fail on 9ef2ccb.

## Live check
Drillchamber: within 3 game days after the update `dfllm events --type GLASS_BLOCKED` shows `sand zone invalid` with `d.aborts` >= 3,
then kern.log `glass: sand collection zone dfllm-sand at x,y,z` on a new tile; the gamelog's `Need valid, active sand collection
zone` count stops growing and a bag of sand appears (inspect orders: CollectSand runs). If the new zone fails too, a second
GLASS_BLOCKED comes (a new series). Within days of painting, grass is unlikely (the tile reader called it bare): read the tile sheet
("yellow sand"? grass?) of the new zone tile by hand and its `dfllm cmd inspect` tile. Weeks later on an open-sky tile it can be
grass regrowth (open: no road/grate over the zone tile; each series paints one more 1x1 zone, at most every request_days). `zone.place type=sand` over 71,82-73,84 z144 must now be refused with `sand floors seen`.
