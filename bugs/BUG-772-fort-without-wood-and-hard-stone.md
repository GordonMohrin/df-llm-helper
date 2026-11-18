# BUG-772 fort without wood and hard stone: limestone counted as flux, barrels / bins / beds stall, the farm comes late
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Lancemoment y372-y373 (new embark: limestone only, no tree, no iron): doors, coffins, tables waited ("stone free 0 (need 15..31): 36 boulders, ... ore, flux, economic or soft stone, 0 usable by the census") although the player had run `stone.use limestone` ("cleared for furniture (22 boulders)"); beds x4 "no logs, the fort has no trees", fortcore stalled 31 d "waits for bed x1", barrels / bins stalled, brewing "no empty barrel", famine food 7 d (no bowyer, no crossbow), farms first drafted at food 30 d
Module: `lua/dfllm/economy.lua` (`ore_of`, `M.free_flux`, `M.hard_report`, `M.stone_unmark`, `plan_containers`, `M.plan_pots`, `T.jmake`, `M.supply_wants`, `M.state`, census `TOOL`), `lua/dfllm/util/contract.lua`, `dfpilot/plan.py` (`farm_low`, `food_draft`), `dfpilot/schema.py` (`stock.nowood`)

## Actual
1. Limestone is a hard stone, but its raws carry the FLUX reaction class. `ore_of` (economy.lua, the census's unusable-boulder test: `r.metals or r.flux or r.econ or r.soft or r.refused`) counted every flux boulder as unusable for the masons whatever the stone-use screen said. `stone.use limestone` cleared DF's economic mark (BUG-734) and the census still called the boulders flux: rock 0, every rock door, coffin, table and chair waited.
2. Barrels and bins (`dfllm:barrel`, `dfllm:bin`) are wood only; with no log the order was simply not made, nothing said so, the caravans were not asked for logs for them, and brewing stood still ("no empty barrel").
3. `farm_low` called for a farm below 60 food days only; a treeless fort has no hunt (no crossbow, no bolts) and no wood, so 60 days is too late.

## Fix
1. `M.freed` (mat_index -> true, persisted in `m.economy.freed`, read back in `M.init`): a flux stone freed for furniture is a plain building stone in `ore_of` (`r.flux` off, ore stays ore). `stone.use` (BUG-734) sets it and, with `economic=true`, clears it (`M.free_flux`). `M.hard_report` (cause `none`, no ore boulder in the fort: steel needs ore, so flux is no smelter reserve) frees the biggest hard flux stone by itself: `act.stone_economic(idx, false)` + `M.free_flux`, one kern.log line, no DECISION. With ore in the fort the flux is kept and the DECISION `no_hard_stone` still names `stone.use` (unchanged). The coffin, door, table, chair and block routes all read the same census, so limestone serves them.
2. `plan_containers` records `st.cont_short[barrels|bins]` when a treeless fort (`M.treeless`: no log for `pieces.treeless_days`, or no tree on the map) cannot make them; `T.jmake` reports MATERIAL_SHORT "no material for barrel, bin: wood only (no rock or clay variant), trade.want wood, pots hold the drink"; `supply_wants` adds the wood want ("beds, barrels, bins"). Beds were wood-only already (BUG-607).
3. Drink goes into large pots: the census counts `pots` / `pots_empty` (TOOL items whose definition is `ITEM_TOOL_LARGE_POT` or lists the use FOOD_STORAGE, `M.is_pot`), `drink_block` counts them as containers ("no empty barrel or pot"), and a treeless fort with barrels short orders `MakeTool ITEM_TOOL_LARGE_POT` of rock at the Craftsdwarf's (`economy.pots`: max_total 24, max_jobs 4; `M.plan_pots`, spends free stone).
4. State `stock.nowood` (1 = treeless fort). `plan.farm_low`: below `FOOD_EARLY_D` (150) food days with `nowood` the farm is drafted at the first room (underground) or surface site; the note says "treeless fort: no wood, no crossbow, no hunt".

## Open
The Craftsdwarf's large-pot job and its subtype id are taken from the raws names (not run live); clay pots (Kiln) are not ordered. Beds stay wood only (trade request). The farm itself still needs a room site on soil (Z4) or surface soil.

## Tests
`tests/lua/test_bug772_773_nowood.lua` (flux-only fort frees limestone by itself and the masons get 36; with ore it is kept and `stone.use` frees / re-marks it; persisted over a reload; treeless fort: barrels / bins named wood-only, wood want, pot order, `stock.nowood`; `M.is_pot`), `tests/test_bug772_773_nowood.py` (`farm_low`, `food_draft`). `tests/lua/test_bug733_734_stone.lua` and `test_bug607_612_econ.lua` pass unchanged.
