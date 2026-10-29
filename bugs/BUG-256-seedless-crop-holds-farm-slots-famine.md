# BUG-256 A crop without seeds holds the farm slots through a famine; the seedless fallback sets such crops
Status: fixed (offline, live-untested)
Severity: high (G4: famine y373 `HUNGRY 2 ... food 0d! meals 0`, starvation `3 cannot reach food`, beside 130 seeds)
Found: 2026-10-29, Run 15 Inkintense (y373 win d6, #474/#489 famine 0 d, census seeds_ok 130 farm_plots 1, cancels `Needs plump helmet spawn`), fix6-food-drink
Module: `lua/dfllm/economy.lua` (`farm_fills`, `M.slot_crop`, `food_plan`, new `M.fd_wants`, `M.trade_wants`)

## Actual
`farm_fills` called `M.slot_crop` only for EMPTY slots (`pid < 0`), so a slot already set (by the farms template / DF
default) to MUSHROOM_CUP_DIMPLE with 0 seeds was never revisited; `slot_crop` itself fell back to the plot's own crop without
a seed. A famine asked for no further plot while the tiles covered the need; with no seed at all nobody asked a caravan.

## Fix
The running season's slot of a crop with no usable seed (census known: `st.seeds_known`) is chosen again, only by a crop with
seeds (kern.log `farm plot P season S: no usable seeds for X: Y instead`, else `no seeds for X and no other crop with seeds grows
there now`, once per slot/crop); later seasons wait for their turn (a crop whose seeds are all in the ground is not swapped
early). No seedless fallback any more. In a famine one more plot is wanted on top of the tiles built, up to twice the
citizens' need (PROJECT_REQUEST farms why=food n=1). Census known, plots standing (or food low) and 0 usable seeds:
`seeds` x20 in economy's caravan wants. The `Needs <x> spawn` cancel is not read (0 seeds covers it).

## Tests
`tests/lua/test_economy_food_run15.lua` `BUG-256: ...`, `tests/lua/test_economy_food.lua` `BUG-256: a famine asks ...`,
`tests/lua/test_economy_supply.lua` FR-17 pin updated (fail on 2b9c009).

## Live check
A plot holding a seedless crop in the running season: kern.log `no usable seeds for ...`, the plot sheet shows the new crop and
PlantSeeds jobs start; `inspect what=trade` / the next caravan's wants list `seeds` when `seeds_ok` is 0; a famine on one plot:
PROJECT_REQUEST farms x1.
