# BUG-582 Caravans `nothing_to_sell` beside 511 bones: nobody makes trade goods
Status: fixed (offline, live-untested)
Severity: medium (three caravans in a row left without a sale)
Found: 2026-11-09, Run 16a i1 Basementflew y426-y428 (`sell: crafts` in the plan, 511 bones, a Craftsdwarfs shop, no MakeCrafts order anywhere), Run 16d i4
Module: `lua/dfllm/economy.lua` (`M.trade_goods`, `M.depot_built`, `DEFAULTS.trade_goods`), `lua/dfllm/trade.lua` (`M.sells`), `config/baseline.json`

## Actual
The plan's `sell: crafts` only filtered what lay at the depot; the only craft order in the kernel was the metal-short one (`metal_short.crafts`, stone / wood only, only while metal is short). A bone fort never made a craft.

## Root cause
`economy.lua`: no planner step kept crafts for sale; `trade.lua` offered no way to ask whether crafts are on the sell list.

## Fix
`trade.sells(K)` (the sources of the current sell list); `economy.trade_goods` (planner 3.26): a built trade depot, crafts on the sell list, a Craftsdwarfs shop and fewer than `economy.trade_goods.min` (30) crafts: one open `MakeCrafts` order of at most `jobs` (10) in bone (corpse leftovers above `bone_keep` 10), else wood above `idle.wood_min`, else free stone (not while stone is short of the rock orders); kern.log says the route once.

## Tests
`tests/lua/test_bug582_trade_goods.lua` (4: bone, wood, stone, no order when enough / no depot / not sold / no shop), `test_economy.lua` (baseline mirror)

## Live check
With a depot, `crafts` in `plan.trade.sell` and bones: a `dfllm:trade_goods` MakeCrafts order within a day; the next caravan has crafts to sell.
