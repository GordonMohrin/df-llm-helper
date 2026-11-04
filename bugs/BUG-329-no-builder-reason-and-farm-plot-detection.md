# BUG-329 'no builder has taken it' for years without a reason; a finished farm plot reads as missing
Status: partly fixed (offline, live-untested): farm detection fixed; the no-builder diagnosis names labor, items, job board,
citizens on the site; the live cause itself still to be read
Severity: high
Found: 2026-11-04, Run 15c Inkintense (FR-BUGS y372-y378), Run 15d Drillchamber, Run 15b Earthboat
Module: `lua/dfllm/runner.lua` (Q.bld_at, pre_occupied, cell_present, piece_built, Q.cls_of), `lua/dfllm/economy.lua`
(M.nobuilder_why, M.build_state)

## Actual
- Inkintense farms c1a18745d4e25dac02 (p(7x5) at 76,50,131): `build_lost at build, missing p`, 8 retries (`dig chunk 0: 7 invalid`,
  `quickfort orders created no manager orders`), parked, then `lost to build_lost (no soil there)`, while plot 17696 at 76,50,131,
  Plump Helmet, was exactly that p(7x5) and grew the fort's only crop. Drillchamber farms c1a187433a25b12d07 `34-43 %
  BLOCKED:build_lost`; BUG-300's phase stayed P0 beside a standing plot.
- `job N not suspended, no builder has taken it` beside 10-31 idle adults: Inkintense FarmPlot 86,87,133 (job 152960, 80+ d),
  doors 64,47,128 / 75,34,131 / 92,99,133, hatch 86,53,126; Drillchamber hatch 89,72,137; Earthboat hatch 55,82,133 and
  y383/y384 `suspended by DF ... no cause readable`. The line never said why.

## Root cause
1. Farm detection (`lua/dfllm/runner.lua:1400`, `:1528`, `:3076` on 9b6f614): every "does the piece stand" check asks
   `dfhack.buildings.findAtTile`, else snapshot's legend. A finished farm plot sets no building occupancy on its tiles (the
   unbuilt FarmPlot 86,87,133 was found: a planned building marks its tiles Planned); findAtTile returns at once on a tile
   without the occupancy bit, and snapshot reads `bld ''`. So the stage's own plot (or one standing before a retry) was invisible:
   pre_occupied did not count it, quickfort called the cell unsuitable, `R.uns` 1 of 1 = build_lost, missing_pieces said `p`.
   (The occupancy behaviour is inferred from the live evidence above, not read in DF's source.)
2. No-builder diagnosis (`lua/dfllm/economy.lua:9110`): for an unsuspended job without a worker it checked the burrow (BUG-298)
   and a walled-in hatch (BUG-313) only; DF hands a ConstructBuilding job only to a citizen with the building's labor who reaches
   its items, and neither was read.

## Fix
1. `Q.bld_at(x, y, z)` (runner): findAtTile, else a farm plot of `buildings.other.FARM_PLOT` whose rectangle (and room extent,
   when it has one) holds the tile; used by pre_occupied, cell_present (missing_pieces, door_walls) and piece_built (seal
   pieces, Q.wait_why). A plot that stands now counts for the farms stage; `missing p` names only plots that do not stand.
2. `economy.nobuilder_why` (appended to build_state's line, the SEAL_STUCK wait, PROJECT_BLOCKED parts and inspect):
   - labor: the building type's labor (DFHack labormanager's ConstructBuilding table: furniture, doors, hatches = Furniture
     hauling, farm plots = Farming (fields), traps/mechanisms = Mechanics) held by no free adult citizen: `no free adult citizen
     has the labor Farming (fields) on (0 of N; a work detail grants it)`; `rec.labor = {labor, n, of}`, `rec.nolabor`;
   - attached items: `its <item> at x,y,z is forbidden` / `... lies off the citizens' walk group` (snapshot.far);
   - `on no DF job posting (posting_index -1)` when that field reads below 0 (a fact for the live check; whether DF offers
     such a job at all is not known here);
   - a job DF suspended: `N citizen(s) on the site now (a walked tile: DF suspends it)` (refuge hatches on a walked stair).
   Q.cls_of: `no labor` (SEAL_STUCK why): the re-place (BUG-274) is skipped for it, it would not help.

## Tests
`tests/lua/test_bug328_329_projects.lua` (5 BUG-329 cases: farms completes over a plot findAtTile misses, extents, labor,
items, citizens on the site); all fail on 9b6f614.

## Live check
Inkintense (`dfllm cmd inspect what=projects` / SEAL_STUCK / PROJECT_BLOCKED): the FarmPlot and door lines now end with the
reason. If they say `no free adult citizen has the labor ...`: the work details (Farmers, Haulers) have nobody with it, the
cause of the years-long waits; if they say nothing more, the reason is still unknown (then: the `posting_index` fact, a unit sheet
of an idle dwarf). The next farms project over a standing plot completes instead of `build_lost missing p`.

## Open
- The labor table is labormanager's mirror of DF's rules, not DF's own code; a building type outside it is not checked.
- Earthboat's hatch 55,82,133 on z133 above the Tiefe+ box: BUG-313 moves a walled-in hatch up the stair; whether a hatch on a
  stair the fort walks is suspended by DF again and again is what the new `citizens on the site` part will show.
- `economy.build_state` itself still says `nothing stands at` for a finished farm plot (it reads findAtTile); only the runner's
  checks use Q.bld_at.
