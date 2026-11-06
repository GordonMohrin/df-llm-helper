# BUG-547 The manager works as a farmer and validates no order for 14 days
Status: fixed (offline, live-untested)
Severity: medium (every order behind him waits: doors, mechanisms, workshop orders)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y397 winter (`runs/run-16d/FR-BUGS.md` line 364: manager Domas HarvestPlants, work order 826 ConstructDoor unvalidated for 14 days, `inspect manager` "no cause found")
Module: `lua/dfllm/economy.lua` (`M.unval_watch`, `M.manager_farm_off`, `M.manager_facts`, `M.labor_flag`), `lua/dfllm/act.lua` (`labor_set`)

## Actual
DECISION_NEEDED `manager_office` (the office zone is walkable, chair and table stand); the manager is busy HarvestPlants / PlantSeeds (labor Farming on), so he is rarely in the office and DF's ManageWorkOrders job waits.

## Root cause
Nothing keeps the Farming labor off the manager: labormanager / the Planters detail give it to every adult, a noble included, and economy only watched the symptom (`manager_watch`, `mgr_stuck`: a decision after 14 days).

## Fix
`economy.manager_farm_off` (from `unval_watch`, once orders are unvalidated for `orders.unval_days` (2) and the manager is appointed and able): if the manager has the Farming labor (PLANT) on, it goes off through `act.labor_set(unit, 'farm', false)` (the labors screen, off only), at most once a day, kern.log "Farming labor off". `inspect what=manager` names "he works as a farmer (HarvestPlants)" as a cause while he does.

## Tests
`tests/lua/test_bug544_547_stone_manager.lua` (3 orders unvalidated: off after 2 days, once, again at most daily if the details give it back; no labor or no unvalidated order: nothing; the cause line), `tests/lua/test_bug546_547_acts.lua`.

## Live check
With orders unvalidated for 2 days kern.log carries "manager <name> (unit N): Farming labor off" and the manager stops showing HarvestPlants.
Open: if the Planters detail ("everybody does this") puts the labor back, the kernel switches it off again once a day (the next step would be taking him out of the detail).
