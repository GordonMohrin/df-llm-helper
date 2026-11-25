# BUG-866 The 'bigger office' lead was false; the manager's real day was never recorded
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i4 Girderroots: '#7121 manager Olin validates nothing for 86 days with a complete office' (3x3 office, chair, table; DF asks room value 1; the player's 5x5 office changed nothing); bursts of validation between stalls of 75-220 days; jobs seen: ConstructBuilding, StoreItemInBin, CustomReaction.
Module: `lua/dfllm/economy.lua` (`M.manager_facts`, `M.mgr_sample`, `M.mgr_obs_text`, `M.manager_farm_off`, `M.unval_watch`, `M.mgr_stuck`)

## Root cause
Vanilla raws: `POSITION:MANAGER [REQUIRED_OFFICE:1]`, no population or rank clause; any chair-and-table office meets it. `manager_facts` still ended with 'nothing the kernel can read is wrong (DF asks room value N: a bigger, furnished office zone, zone.place type=office)', which sent the player into a dead end. The chores that take the manager away (BUG-837) stayed on because `economy.diag.mgr_chores` is false, and nothing recorded what he did day by day, so 'office vs path vs chore' could not be settled.

## Fix
The false lead is gone: with no other cause the text says `the office meets what DF asks (room value N)` plus the measured days. `M.mgr_sample` records once per game day while orders wait (`p.mgr_obs`: days seen, days inside his office zone, his job per day); `inspect what=manager` and the manager_stuck question print `seen N game days with orders waiting: A at his office zone, B on a ManageWorkOrders job; jobs: ...`. Past `orders.mgr_stuck_days` (5) the other chores (Herbalism, Spinning, plant processing, giving water) go off for him whatever `diag.mgr_chores` says (`manager_farm_off(K, p, true)`).

## Tests
`tests/lua/test_bug544_547_stone_manager.lua` (BUG-866: chores off after mgr_stuck_days, daily samples), `tests/lua/test_economy_drink.lua` (text adapted).

## Live-Erwartung
i4: `inspect what=manager` prints the jobs of the last days; kern.log 'labors off (spin, ...)' after day 5 of unvalidated orders. Whether validation gaps shrink is the measurement; NOT promised. NOT done: office size/value re-check against noble growth (the raws give no growth clause; value 1 is trivially met), moving an office into the core (the walk check of `inspect manager` already names a missing path).
