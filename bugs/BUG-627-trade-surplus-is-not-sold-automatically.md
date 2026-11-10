# BUG-627 The caravans buy nothing: `trade.sell crafts/thread/drink` and 169 items of other kinds
Status: fixed (offline, live-untested)
Severity: medium (no trade from y426 to y453 in a fort with food for 3000 days)
Found: 2026-11-09, Run 16a i1 Basementflew y443-y453 (every caravan `nothing_to_sell [kind=169]`; the first trade since y426 came after bone, food, meal and plant were added by hand; drink in the list took the stock from 944 to 396 days)
Module: `lua/dfllm/trade.lua` (`L.surplus_sell`, `wants`, `override`), `lua/dfllm/economy.lua` (`M.surplus_days`)

## Actual
`plan.trade.sell` is a list the player keeps up by hand; goods of other kinds lay at the depot but were never offered (BUG-609 counted them as `kind`). A player who added drink to it sold the water supply as well.

## Root cause
`trade.wants` returned the sell list as given. Nothing in the kernel knew which stock is surplus (food above its days, bone) and which is not (drink).

## Fix
`L.surplus_sell(sell, days, known, cfg, noauto)`: a non-empty sell list (an empty one sells whatever lies at the depot) gets `bone` always, `food` (types FOOD, MEAT, FISH, CHEESE, EGG, PLANT: plants and meals) while `economy.surplus_days` food_d >= `CFG.SURPLUS_FOOD_D` (300) and `drink` only while drink_d >= `CFG.SURPLUS_DRINK_D` (600). Kinds the list names stay (also drink below the floor); `CFG.SURPLUS = false` leaves the list alone; no stock reading (economy off) adds nothing; a kind taken out with `trade.want sell_remove` is remembered (`ov.noauto`) and is not added again. `trade.want` replies and `inspect what=trade` show the effective list.

## Tests
`tests/lua/test_bug627_trade_surplus.lua` (5: surplus kinds, the floors, player lists and empty lists, sell_remove, through the module)

## Live check
`dfllm cmd trade.want '{}'` in Basementflew lists `sell` with bone, food (and drink only with drink_d >= 600); the next caravan sells plants, bones, meals; the drink days stay above the economy's target.
