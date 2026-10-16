# BUG-025 trade looks at the manifest depot while the merchants unload at another one: "nothing_listed" for a caravan that has goods
Status: fixed and confirmed live (2026-10-16, Catten y415: depot 17590 chosen, 135 goods listed, traded ratio 1.68)
Severity: medium (a whole caravan visit is lost; the kernel reports "no goods" although the merchants carry some)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97, y414), Catten's caravan, Claude playing
Module: `lua/dfllm/trade.lua` `find_depot` (used by `step_wait`, `inspect what=trade`, the depot keeper)

## Actual
Two built depots: 17598 at (104,126,122), the manifest depot with 3 items and no merchant goods, and 17590 at (107,124,124), built by hand, where the merchants unloaded
(49 `flags.trader` items inside its `contained_items`, 128 more in the merchants' inventories). Probe during the visit:
```
caravan 0 entity 29 goods# 0 animals# 0 trade_state 3   (AtDepot)      merchants: DWARF 27450, CAMEL_2_HUMP 27451 at (108-109,125,124)
depot 17590 (107,124,124) contained 97 trader items 49      depot 17598 (104,126,122) contained 3 trader items 0     both accessible=false
inspect what=trade -> depot 17598, goods_items 0      CARAVAN trade with Catten failed: nothing_listed
```
`find_depot` returned the depot that contains `manifest.depot`, so everything (goods list, trader check, "nothing listed" timeout) was evaluated at the wrong building.
`caravan.goods` is empty once the goods are unloaded, so the second source (trader items in the depot) was the only one, and it looked at the empty depot.

## Expected
The depot the merchants actually use wins: the built depot with the most trader-flagged items; with none anywhere, the manifest depot, then the first built one.

## Fix
`trader_items(b)` counts trader-flagged `contained_items` (<= `DEPOT_ITEMS`); `find_depot` returns the depot with the most, else the manifest depot, else the first built one.
Test `BUG-025` (two depots, goods in the second): fails on the old code (depot 50), passes now (51); with no trader goods the first built depot (50) is kept.

## Confirmation (y415 autumn)
`inspect what=trade` named depot 17590 with 135 merchant goods (30 kinds); `CARAVAN traded with Catten, ratio 1.68` (sold 27 totems + goblet 1480, bought 20 cloth, 1 anvil, 2 thread, 652). The kernel kept `nothing_listed` only for the y414 visit.

## Not solved
Both depots report `accessible=false` (no wagon path from the map edge?). If the merchants walk in but the wagons cannot, the goods are still unloaded at the depot edge; only DF's own path check decides.
The broker traded at 17590 although `accessible=false`, so that flag is no reliable wagon-path test.

Related: BUG-016 (the same visit logic), FR-43 (depot keeper)
