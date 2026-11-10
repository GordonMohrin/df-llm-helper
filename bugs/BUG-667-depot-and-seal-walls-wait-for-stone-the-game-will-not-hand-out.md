# BUG-667 Depot and seal walls wait for stone the game will not hand out while logs lie unused (no caravan can trade: a vicious circle)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y439 (Pop 12): DEPOT_MISSING 'building material: blocks', depot project build_lost, a seal wall 'no item' for 90 days, trade.want stone never answered because without a depot there is no trade; 99-114 logs in stock
Module: `lua/dfllm/economy.lua` (`M.bm_route`, `M.stone_none`, `T.jmake`)

## Actual
Everything that builds from "building material" (depot, walls, workshops) waited for blocks or boulders; the logs were not the route.

## Root cause
`M.bm_route` took the first of blocks / boulders / logs that buildingplan had on and the census had in stock. `inv.rock` is every free boulder, so a fort whose stone DF refuses (BUG-545) or whose boulders are all refused / economic / soft routed the depot and walls to boulders, the wait went on, and logs were never switched on or chosen.

## Fix
`M.stone_none(inv, now)` = DF refused the stone (`hard_denied`) or the census holds boulders and none usable. Then `bm_route` leaves boulders out while there are logs (not for a furnace or forge), `T.jmake` turns buildingplan's `boulders` off once (`p.bpoff`, kern.log 'buildingplan boulders off') so no wall or depot reserves a boulder nobody may take, and on again (`boulders on again`) when the stone is usable. The depot, a workshop or a wall then takes logs.

## Tests
`tests/lua/test_bug665_668_stone_wood.lua` (denied stone + logs: logs route, boulders off, back on with new boulders; usable stone: nothing changes).

## Live check
Trumpetrealms-like fort (stone refused, logs): the `depot` project leaves build_lost, kern.log 'buildingplan boulders off', then a caravan trades.
Open: a depot built of logs burns like any wooden building (furnaces and forges keep needing stone); the 14-day denial hold flips boulders on again when it lapses without new cancels.

## Not changed (reported)
Rocksblush (Run 16b i2, new fort y414-y415, 0 wood 0 stone 0 blocks, Still / Fishery / Depot suspended): `baseline.lua:393` sets autochop's target only; DFHack autochop fells trees only inside its chop burrows and nothing in the kernel designates a tree or a stone dig when the first census reads wood 0, rock 0 and blocks 0. A start pass (designate the nearest reachable trees, else a stone dig on the nearest hard wall, before the aqshaft) is a new feature, not a fix of the census; reported as FR, needs a live look at what autochop does with no burrow.
