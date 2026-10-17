# BUG-042 Drink falls from 93 to 32 days beside 15 idle stills: the manager validates nothing (his office has no chair and no table)
Status: fixed in <commit> (the cause live confirmed y471 winter d42: a table and a chair built in the office let the
manager take ManageWorkOrders at once, unvalidated orders 112 -> 51, the brew orders validated; the fix offline,
live-untested)
Severity: critical (drink 32 days with 19 patients, patient thirst 25394; deaths of thirst were near)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y471 summer d24 - winter d42, kernel b873eb6 then 0038b55, ~54
citizens, from the game session's report (read-only Lua, kern.log, cli.log)
Module: `lua/dfllm/economy.lua` (validation_watch, manager_watch, scan_orders/T.orders, plan_supply, plan_containers,
M.gather_low), `lua/dfllm/act.lua` (manager_office), `lua/dfllm/runner.lua` (orders), `dfpilot/wake.py`, `dfpilot/cmd.py`,
`dfpilot/bp/rooms.py` (office)

## Actual
- `drink 93d!` in summer (y463 588 d, y469 200 d), 18 days later `drink 32d!`; 15 stills, none with a job; 739 then 263
  drink items, 260-275 PLANT, 585-3079 PLANT_GROWTH, 85 barrels (12-16 empty).
- 445-446 manager orders; brew orders: 1250 BREW_DRINK_FROM_PLANT x10 (the kernel's dfllm:drink, logged `order
  dfllm:drink x10 (drink_d)`), the session's 1260 x30 and 1261 BREW_DRINK_FROM_PLANT_GROWTH x30: `validated=false`; 12/13
  BREW_* x2 (library/basic, Daily) validated but inactive. 112 of 446 orders unvalidated, 334 validated.
- The manager (Astesh Shorastthum, hf 5769) alive, idle, unhurt. His Office zone 18631 (127-129,73-75 z141) held 0
  chairs and 0 tables; his bedroom 19235 (136-138,68-70 z137) is no office.
- By job: ConstructDoor 110, MakeWeapon 39, ConstructCoffin 26, ConstructBlocks 24, ...
- The fishery: kern.log `fishery: none built, 6677-7077 raw fish, fishers at work, food 80-105 days: request (35-49 days
  since the last request)` x4; cli.log `follow AUTO_FAIL {} workshops: bp.sites.rank(workshops): workshops: nothing left
  to build` at 1792251949, 1792252063, 1792252198, after the reload to b873eb6 (the BUG-038 placement fix inside).
- 14 of 32 adults idle beside 241 unclaimed GatherPlants jobs.

## Causes (from the code, 0038b55)
1. **The manager validates nothing without a chair/table in his office, and nothing checked it.** `act.manager_office`
   (act.lua:1097-1110) only assigns a free Office zone; once he holds one it answers `has office` (1103) whatever stands
   in it. DF posts no ManageWorkOrders job without the desk (live L1 note at economy.lua:2224; live proof: a table and a
   chair built at 127,74 / 128,74 and he took the job).
2. **The unvalidated-order watch was a ratio.** `validation_watch` (economy.lua:2227-2252) speaks only while fewer than
   10 % of all orders are validated (2243 `valid * 10 >= total` returns): 334 old validated orders kept it silent while
   every new order (the brew orders among them) waited for months. `manager_watch` (2393) covers only an injured, moody
   or gone manager.
3. **An unvalidated brew order is "live" and blocks the next one, silently.** `scan_orders` counts any order with
   `amount_left > 0` (1107) as open; `plan_supply` skips an open tag (1302) and `T.orders` a live one (5202). So the
   kernel's dfllm:drink x10 stood unvalidated, no new order was made and nothing logged it while drink fell to 32 days.
   Its id 1250 is below the session's 1260/1261 (DF hands out `manager_order_next_id` in order), so it existed before
   the session's hand orders although the first census reported no brew order; x10 fits the 170-day target at about 164
   days, i.e. it was made early in the fall.
4. **Fruit was never brewed.** The only kernel brew order is BREW_DRINK_FROM_PLANT with a PLANT/DRINK_MAT condition
   (economy.lua:244-247); BREW_DRINK_FROM_PLANT_GROWTH exists only in baseline's prioritize line, so 3079 growths (the
   brewable fruit among them) never reached a still.
5. **Brews waiting for barrels ordered none.** `plan_containers` wants barrels only below `min_empty` 4 empty ones
   (1335) and caps the total at `grow_total` 80 (1338-1339): 12 empty of 85 for 60 waiting brews made no barrel order.
6. **No drink line spoke.** STOCK_LOW drink_d is class B once; the thirst decision (alarm_check) only below 10 days.
7. **Gatherers only for food.** `M.gather_low` adds plant gatherers only below `food.pre_days` 30 (5015).
8. **The 110 ConstructDoor:** the runner's quickfort `orders` call orders an item for every cell without a building
   (runner.lua:1535); seals have `orders=1` stages (defense.py:386, 395), a build_lost retry resets `orders_done`
   (runner.lua:3226), so every seal, retry and remake whose planned door was gone ordered another (rock) door while the
   older ones still waited for stone. No dfllm tag grows: economy keeps one order id per tag (persist `m.economy.orders`,
   tag -> id; DF orders carry no tag field).
9. **The fishery AUTO_FAIL after b873eb6.** With the code in the repo the fishery request is placed (tests/test_bug042.py
   replays it with the real templates and a manifest listing the destroyed fishery at 121,115,139). The live text is
   exactly `cmd.place` without `need=["Fishery"]`: a follow process started before the BUG-038 pull (it keeps the code it
   imported), or a workshops request without `need` (economy's tannery request after the sieges hit the workshop hall:
   wake.py:420, cmd.py:915 skip every moodable type the manifest lists). Not decided offline (below).

## Fix
- **Office check** (`M.office_check`, daily in validation_watch; `M.office_of`, `M.office_spots`): the Office zone
  assigned to the manager must hold a built chair and table (`office.table`); a missing one (neither built nor planned)
  is placed on a free floor tile of the zone (revealed floor, no building, the table beside the chair) through
  `runner.repair` (quickfort `#build` `c`/`t`, buildingplan waits for the item, T.jmake orders it), at most every
  `office.retry_days` (7); kern.log `manager office 18631 has no chair, no table: chair at 128,73,141, table at
  129,73,141 placed (rp...)`, MANAGER_OFFICE (B). A placed piece not built names the free items (census `chairs`,
  `tables`): `not built: no free chair; add it at a workshop by hand (its order waits for him too)`.
- **Unvalidated orders by age** (`M.unval_watch`, replaces the ratio): the 8 lowest unvalidated order ids with their
  first-seen tick (`m.economy.uv`); once one waits `orders.unval_days` (2) with a manager appointed and able,
  DECISION_NEEDED manager_office (A, util/cadence once per reason) `112 manager orders not validated for 18 days (70 brews
  among them): manager office 18631 has no chair, no table` with the fix in q; reasons: the office (above), `the manager
  has no office zone` (fix: an Office zone with a chair and a table, `bp.place office`), else `manager <name> validates
  nothing (his office has a chair and a table)`. ORDER_STUCK/inspect orders: `unvalidated: <reason>`. State
  `orders.unval`, `uval_d`, `mgr`; status `orders: 112 unvalidated, oldest 18 d: ...`.
- **Drink:** `dfllm:drink_fruit` (BREW_DRINK_FROM_PLANT_GROWTH, PLANT_GROWTH/DRINK_MAT >= 2, an empty food-storage
  container); the deficit's jobs split by the census' brewable stock (`brew_p`: PLANT with DRINK_MAT, plump helmets
  always; `brew_g`: PLANT_GROWTH with DRINK_MAT; `M.brew_share`); a removed (finished) order comes back next run with
  its kern.log line. Barrels: below the drink target the brews the open BREW_ orders want (`barrels.brew_wait` 30 at
  most) are empty barrels wanted too, past grow_total. `M.drink_low`: below `drink.low_d` (60) and from `alarm.days` up,
  DECISION_NEEDED drink_low (A, cadence) with `block` (still, brew, unvalidated, plants, barrels, brewer) and `auto`
  (brew, office, barrels, gather); state `stock.dwhy` (status `drink: 70 brews wait for validation: manager office 18631
  has no chair, no table`).
- **Gatherers:** also below `gather.drink_d` (60) drink days while the brewable plants are fewer than the deficit to the
  drink target needs (5 drinks a plant); off once food >= off_days and drink >= `gather.drink_off` (100) or the plants
  suffice; the BUG-038 guards unchanged. With 3079 growths the live fort would get none (the stills lacked validation,
  not plants).
- **Door orders:** a door/hatch cell gets no quickfort order while the open one-time orders of its job hold
  `runner.CFG.orders_cap` (10) items (kern.log `... 1 door cells get no manager order: 110 open ConstructDoor orders (cap
  10)`); T.jmake orders what a planned door still waits for.
- **Office template:** chair and table side by side (`office` golden updated).
- **follow:** its heartbeat carries `code` (a digest of the dfpilot .py files it imported); status/brief `follow: OLD
  CODE (dfpilot changed on disk since it started): restart dfllm follow`. The tannery request passes `need=["Tanners"]`
  (place keeps it out of `skip`). RULES §13 names it.
- Config (validated: `fairplay.economy_errors`, `lint --config`): `economy.drink.low_d`, `orders.unval_days`,
  `office {table, retry_days, max_tiles}`, `gather.drink_d`/`drink_off`, `barrels.brew_wait`, the second supply entry.

## Not changed (judgment)
- **Brew tasks straight at a still** (the workshop's add-task, no manager): not built. The cause was the validation and
  the office check fixes it; a hand-built CustomReaction job needs its reagent job_items as DF's UI builds them, which no
  offline fake can check, and DF 53.16 crashed four times on malformed make-item work (FR-39). If wanted, it needs
  Gordon's yes and a live test (behind a flag, off).
- The DF item conditions stay (2 brewable plants, an empty food-storage container); large pots count as DF counts them.
- `seal: CUTOFF not confirmed (audit read 51 food, 0 drink, 51 bed cut)` is BUG-021's false-positive guard (the walk
  groups joined again); 0 drink = no citizen was cut from drink. `supply brake on: P0` only slows the clock (arbiter,
  P0 below 60 drink/food days; the fort sits in P0 because its farms project is build_lost, BUG-037); it never touches
  orders.

## Not decided offline (the read-only live data that decides it)
- Which follow failed the fishery: the start time of the running `dfllm follow` process against the pull to ba45a2a/
  b873eb6 (Windows: `Get-CimInstance Win32_Process -Filter "Name like 'python%'" | select ProcessId,CreationDate,CommandLine`),
  `<save>/.follow.json` `jobs.fishery.need` while a request is in flight, and `dfllm events --type PROJECT_REQUEST --limit
  0` `why` (fishery or tannery) at the AUTO_FAIL epochs (cli.log lines just before each). After the update: `dfllm status`
  shows `follow: OLD CODE` for a stale follow.
- Whether the 110 ConstructDoor are the runner's: kern.log `<proj> seal.build: N manager orders, M items` (and
  `seal.plant`) summed over the seals and their retries (`build_lost at ..., retry n/8`), and `dfllm cmd inspect
  '{"what":"persist","key":"m.economy","field":"orders"}'` (economy's own order ids by tag).
- Whether DF needs the table as well as the chair: the live fix built both at once (the check places both; config
  `office.table` false checks the chair only).

## Tests
`tests/lua/test_economy_drink.lua` (new: the live replay with office 18631, its chair and table placed, the age watch,
the reasons in state/inspect/decisions, quiet once they stand; a complete office, a planned chair, no office zone; the
ratio rule gone; fruit brewing, the split and a re-created order; barrels for 60 waiting brews; drink_low's blockers),
`tests/lua/test_economy_gather.lua` (drink-low gatherers), `tests/lua/test_runner.lua` (door order cap),
`tests/lua/test_economy_orders.lua` (adjusted: the office reason replaces the material reason of an unvalidated order),
`tests/test_bug042.py` (new: status lines, follow OLD CODE, the heartbeat stamp, the fishery live replay with the real
templates, the tannery need, config validation); each new test fails on 0038b55 except the fishery replay (it passes
there: the in-repo code places the fishery; it pins the live text to `place()` without `need`).

Related: BUG-038 (fishery request, gatherers), BUG-037 (P0, the parked farms), BUG-021 (CUTOFF), FR-39, live L1 (office).
