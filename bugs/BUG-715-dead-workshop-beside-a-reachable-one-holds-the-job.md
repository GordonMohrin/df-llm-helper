# BUG-715 A dead (flooded or unreachable) workshop beside a reachable one holds the job: meals 1 beside 1000-3000 food days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y470-y480 (a second Kitchen 29,112,117 in the flooded level z117 beside a reachable kitchen: `inspect workload` 'unreachable PrepareMeal x1', meals 1, HUNGRY at food 1000-3000 days; no command removed a dead workshop)
Module: `lua/dfllm/economy.lua` (`M.shop_reach`, `M.dead_scan`, `M.dead_note`), `lua/dfllm/act.lua` (`workshop_retire`)

## Root cause
BUG-654 (`economy.lua` `M.cut_scan`, line 10612) judged a workshop type cut off only when EVERY built shop of the type had no walkable ring tile on a citizens' walk group (`e.ok == 0 and e.cutn == e.n`). With a second, reachable Kitchen the cut one was simply ignored: `shop_reach` (line 10447) did not even keep the building ids. DF's manager still gave the PrepareMeal job to the flooded kitchen (it does not test the walk group), the job stayed 'unreachable', the order slot was held, meals stayed at 1. The kernel never named it (the cook stall text said 'kitchen idle with N cook ingredients') and no act removed a workshop.

## Fix
- `shop_reach` keeps `id` per shop and lists the cut shops of a type in `e.dead = {{id, at, grp}}`.
- `M.dead_scan` (line 10560, from `cut_scan`, daily, PEACE only): a cut shop of a type that has a reachable shop for `CUT.days` (3) days is dead (`p.deadws[id]`). It is named once (ORDER_STUCK B kind `workshop`, `d.id`, `d.retired`, kern.log: where, 'walk group 0: no walkable tile round it, flooded or walled' or the other group, the citizens' group, 'a reachable Kitchen stands and takes the jobs') and retired with the new act `workshop_retire(id)` (act.lua line 1338): the workshop profile's `max_general_orders` 0 (the manager's jobs go to the other shop), `dfhack.buildings.deconstruct` (queued Remove Building job; a builder must walk there, so a flooded shop stays marked while the manager is already off it). At most 2 a day, asked again after 30 days while the shop stands. A shop back on a citizens' walk group, or an unread (hidden) ring, is never retired. A type with only dead shops is still BUG-654's case (a new one is asked for, nothing removed).
- `M.dead_note` names the dead shop in the cook stall text (`cook_watch`).
- Contract: act `workshop_retire` (owner economy), `p.deadws`, ORDER_STUCK extra keys `id`, `retired`.

## Tests
`tests/lua/test_bug715_718_food.lua`: flooded second kitchen retired once after 3 days (not the reachable one, not again inside 30 days, again after 30), a shop on another walk group, hidden ring and a shop coming back, the stall note, and `act.workshop_retire` against DF fakes (profile, queued, refused). No bridge, gate, refuge, lockdown or seal behaviour changed: no siege traffic test.

## Live check
kern.log 'dead workshop Kitchen <id> at x,y,z (walk group 0 ...)'; `inspect what=workload` loses 'unreachable PrepareMeal'. Open: `profile.max_general_orders` on a workshop is a DFHack name read from the structures, not run live; a flooded shop's Remove Building job waits until a builder can reach it (the profile already holds the manager off); a Kernel reload is needed.
