# BUG-025 trade looks at the manifest depot while the merchants unload at another one: "nothing_listed" for a caravan that has goods
Status: fixed (offline, tests/lua/test_trade_ledger.lua), live reload pending the next caravan
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

## Not solved
Both depots report `accessible=false` (no wagon path from the map edge?). If the merchants walk in but the wagons cannot, the goods are still unloaded at the depot edge; only DF's own path check decides.
Whether the broker could trade at 17590 is untested; the next caravan shows it (`inspect what=trade` now names the depot).

Related: BUG-016 (the same visit logic), FR-43 (depot keeper)
