# BUG-058 Farm plots stand at -1 for the running season (autofarm empties what the kernel set); underground plots hold surface crops; farms requested again after build_lost
Status: fixed in eb4d838 (offline, live-untested): the slots of the running season are filled right after the census
(T.slotnow, edible crops first when food is low), a crop of the wrong kind for the plot's tile is replaced (the tile is
read through the new `snapshot.plot_under`), autofarm is disabled below 30 food days or when a slot the kernel wrote was
emptied or changed again (enabled again from 90 food days after 14 days, never after two wipes; `farms.autofarm`
'auto' | 'off' | 'keep'), and after one farms project lost to build_lost the kernel requests no further one until it is
cancelled (DECISIONS 9)
Severity: critical (wrong decision: famine, food 17 days, 39 idle with 0 PlantSeeds jobs; the Run 13 post-mortem lists it
among the causes of the hunger years y510-y513)
Found: 2026-10-18 .. 2026-10-22, Run 13 (Wheelsblows, region2-site84, y512), Run 11 (five parked farms projects); notes 3
and 44 of `bugs/RUN11-offene-bugs-und-FR.md`
Module: `lua/dfllm/economy.lua` (farm_fills, M.slot_crop, T.farmslots, T.crops, T.farm, food_plan), `lua/dfllm/runner.lua`
(M.pending), `lua/dfllm/snapshot.lua`, `lua/dfllm/baseline.lua`

## Actual (live, from the notes)
- Run 13 y512: 8 plots (809-816) had `plant_id[season] = -1` for the running season (slots of other seasons set), so 0 PlantSeeds
  jobs, 39 idle, one plant on all plots, food 17 d. Set by hand (Lua) the slot read -1 again within ~30 s (autofarm active,
  economy `slot_crop` runs "KERNEL_SLOW demoted x2"). With `disable autofarm` the slots stayed.
- The new plots on z149 (underground) held TURNIP, PARSNIP, QUINOA; hardly a PlantSeeds job; after the switch to GRASS_WHEAT_CAVE,
  POD_SWEET, MUSHROOM_HELMET_PLUMP four PlantSeeds ran at once.
- Run 11 (note 3): five `farms` projects `build_lost, parked` (no soil), each requested by the kernel after the one before.

## Cause (proved from the code at f17e2b3)
1. **Late and indirect.** The slots are filled by `T.farmslots` (economy.lua:6442), the 34th of 39 tasks of the daily run
   (`FULL`, 6633; 34th of 39), one DF write per frame and only `farms.per_day` 16 a day, after every sliced task before it; a demoted
   economy (KERNEL_SLOW) takes weeks to get there. Nothing fills the slot of the running season first.
2. **A second writer.** autofarm (enabled by baseline, `plugins`, baseline.lua; thresholds written by `T.crops` 5666 and
   `T.farm` 5636) writes `plant_id` of every plot, and the kernel's own accounting (`food_d`, 3 plants a season per citizen)
   does not consult it. That it empties what the kernel set is proven live by note 44 (the slots stayed with
   `disable autofarm`); its exact rule (by DFHack's source as remembered: a plot gets "no crop" when none of its crops is
   below its threshold) is not decided offline. Nothing in the kernel noticed its writes being undone.
3. **The crop kind comes from the slots, not from the plot.** `farm_fills` (4066) takes `under` from the *first filled slot*
   (4078): a plot whose slots hold surface crops stays a surface plot for the kernel (autofarm filled the z149 plots with
   surface crops), and an all-empty plot has `under == nil` and is "left to autofarm" (4085; test_economy_supply.lua
   'unknown biome'). DF makes no PlantSeeds job for a crop that cannot grow on the plot's tile.
4. **Fill order.** `M.slot_crop` (4049) takes the crop with the most usable seeds that fits; with food low that may be a dye or
   fiber crop that feeds nobody.
5. **Requests after a lost project.** `food_plan` asks again whenever `runner.pending('farms')` is 0 (3642); a project blocked
   for good by build_lost is not pending once parked (runner.lua `Q.live`, BUG-037), so the next request, then the next.
   `ipairs(world.raws.plants.all)` counts from 0 in DFHack (`i` is the raw index): `plant_index` and `plant_info` already use it
   as the index; the hint of note 44 stays true for new code.

## Fix
- **T.slotnow** (right after `scan`): the running season's empty slots and the slots holding a crop of the wrong kind (tile
  known) of at most `farms.now_max` 24 plots a run; edible crops first while food is below `food.pre_days` or in a famine
  (`M.food_plant`: an edible structural or growth material). kern.log `farm plots: N slots of the running season filled at
  once`. The daily `T.farmslots` stays for the other seasons and takes the same wrong-kind rule.
- **The plot's tile decides.** `snapshot.plot_under(x, y, z)` (corner of the plot): open sky = surface,
  subterranean = underground, hidden or roofed-and-not-subterranean = unknown (then the old rule: the first filled slot, or left alone). A wrong-kind crop is replaced only by a crop with usable seeds, so a wrong reading of the tile never costs a planted slot.
- **autofarm** (`M.af_policy`, in T.slotnow): the kernel remembers the slots it wrote (`m.economy.af.fs`) and counts the ones
  found emptied or changed (`af.wiped`). `farms.autofarm` `auto` (default): `disable autofarm` below `af_off_days` 30 food
  days or at the first wiped slot (kern.log `autofarm disabled (food 17 days | N season slots it emptied or changed again)`),
  `enable autofarm` again from `af_on_days` 90 food days after `af_hold_days` 14 days and never after two wipes; `off`: disabled at
  every boot and not enabled by baseline; `keep`: never touched. While it is off `T.crops` / `T.farm` write no thresholds.
  `disable autofarm` is on the allowlist (a DFHack command a player may run).
- **No more farms after a lost one.** `runner.lost(tpl)` = projects of the template blocked for good by build_lost (retries
  spent), parked or not; `food_plan` makes no `farms` request while one stands (kern.log once: `farms: project X lost to
  build_lost (no soil there?): no further farms request until it is cancelled (bp.cancel) or the farms are placed
  elsewhere`), the food_low blocker `farms` names it. `bp.cancel` or a new site ends it. The kernel cancels nothing.

## Not decided offline (the read-only live data that decides it)
- That `subterranean` / `outside` of the plot's corner tile is the flag the game's plot sheet uses for its crop list (and what a roofed, not subterranean surface plot offers: the reading is nil there, so nothing is guessed): read
  `dfhack.maps.getTileFlags(x1, y1, z)` of a surface plot and an underground plot (the z149 ones) and compare with the crops
  the sheet offers (`autofarm status` lists the crops it can plant). A wrong guess costs a wasted slot, never a destroyed one:
  `plot_under` is nil on a hidden tile, and nothing is replaced then.
- That autofarm's -1 is its "nothing short" case: kern.log `autofarm disabled (N season slots it emptied or changed again)` after
  a kernel fill, with the plot's `plant_id` read before and after.

## Tests
`tests/lua/test_economy_supply.lua` (all-empty plot filled from its tile, edible first when food is low, underground plot's surface
crops replaced, autofarm off below 30 days / back from 90 after 14 days / keep / off, a wiped slot, two wipes),
`tests/lua/test_economy_food.lua` (a lost farms project stops the requests, cancelled they go on),
`tests/lua/test_runner_queue.lua` (`runner.lost`), `tests/lua/test_snapshot.lua` (`plot_under`), `tests/lua/test_baseline.lua`
(`off` is not enabled), `tests/test_bug057_059.py` (knobs, allowlist); each new test fails on f17e2b3.

Related: FR-17 (season slots), BUG-037 (parked projects), DECISIONS 9.
