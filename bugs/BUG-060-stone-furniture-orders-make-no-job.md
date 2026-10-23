# BUG-060 Eleven stone door orders made no job for months with 635 boulders; five buildings waited for doors; wood doors ordered by hand were built at once
Status: fixed in b1ac67a and 322bd4b (offline, live-untested; the cause behind the missing jobs is most likely BUG-061, not proven)
Severity: high (Run 13: guildhall, hall, cistern and farms "stalled" on "buildingplan: waiting for materials (door x5)")
Found: 2026-10-23 from the game session's note 42 (Run 13 Wheelsblows y508) and note 10; kernel of Run 13
Module: `lua/dfllm/economy.lua` (T.ocheck, T.stale, M.stale_reason, M.piece_orders, T.jmake), `lua/dfllm/orderfix.lua`,
`lua/dfllm/orderlib.lua`

## Actual
- 11 manager orders `ConstructDoor INORGANIC` (OneTime, validated, `is_active`) produced no job for months; the masons
  stood empty (note 42: "Masons leer"), 635 usable boulders lay in the fort. Five builds (guildhall, hall, cistern,
  farms) stood "stalled" on "buildingplan: waiting for materials (door x5)".
- By hand: `order.add ConstructDoor material_category=[wood] amount=5`: the carpenters built the doors at once.
- Note 10: do the brew orders need more furniture in the manager's office than a table and a chair?

## Cause (base f17e2b3)
What is proven from the code:
1. **A stone order without a job is "made" for ever.** `M.piece_orders` (`economy.lua:4686`, line 4694) counts every open
   rock order of the piece's job as `made` while `M.rock_left` is not negative, whether or not it has ever made a job;
   `T.jmake` (`economy.lua:4769`, the call at 4794) then orders nothing more for the planned door. Eleven stale rock door
   orders and 635 boulders therefore meant no wood order, ever, while the carpenters stood ready. The wood fallback only
   runs on stone shortage (`wood_orders`, `economy.lua:1963`; boulders below 20, or `rock_left` < 0 in `piece_orders`).
2. **The runner's door cap turns it into a block.** `runner.lua:1516-1558` (`orders_cap` 10, BUG-042) places no new
   quickfort door order while the open ConstructDoor orders hold 10 items; 11 stale ones kept the cap reached.
3. **The kernel could not see an order without a job.** Nothing read `job.order_id` (df-structures `job.order_id`, since
   0.43.01); `M.order_reasons` (`economy.lua:3861`) knows only a missing workshop, input, labor or validation, and every
   one of those was fine here, so `T.ocheck` (`economy.lua:5818`) reported nothing. "Validated, active, no job" was
   invisible.
What is not proven (the code cannot show why DF made no job):
4. **Most likely the same cause as BUG-061.** Note 45 (same run, y523) found 31 EngraveSlab orders in the masons'
   five slots and lists exactly the same victims (doors, coffins, tables, blocks, slabs); removing them made the masons
   productive at once. Note 42 is the earlier sight of that jam (y508). Its competitors were checked against the code:
   the material class (`OL.mat_class` of `mat_type 0, mat_index -1` is `rock`, `orderlib.lua:43-55`; DF's generic
   INORGANIC is any non-economic stone), the mason labor (`ctx.labor_ok`, `economy.lua:3835`), and a stockpile or item
   condition (quickfort orders carry none) all read fine, but "635 usable boulders" is the session's count: ore, flux,
   economic and soft stone do not feed furniture (`stone_free`, `economy.lua:1957`), and jobs for stone the masons may
   not use also cancel and fill slots (the same jam).

## Fix (b1ac67a and 322bd4b)
- **Job links** (`OF.shops`, `lua/dfllm/orderfix.lua`): the job lists of the built workshops and furnaces, each job with
  its `order_id`; read once per daily order check (T.ocheck's first slice).
- **Stale orders** (`T.stale`, daily after `jmat`, sliced 50 orders a frame): per one-time, validated order without item
  conditions in a shop-bound job (`OL.workshops`), with no known blocker (a jam victim counts): `p.ostale[id]` = amount
  left and since when; it restarts when the amount changes or a job from the order stands in a workshop. After
  `stale.days` (10), or `stale.wait_days` (3) when a planned building waits for that piece (`r.jb.mq`), in PEACE and
  RECOVERY only (the clock waits otherwise), at most `stale.per_day` (6) a day, the order is
  1. a stone furniture order with a wood variant (`wood_orders.jobs`: door, cabinet, chest, coffin, table, throne, armor
     stand, weapon rack, hatch cover, grate, floodgate), logs beyond the moods' floor and a carpenter's shop:
     re-entered in wood (`act.order_material`, as the shortage path does);
  2. else a simple order (`OF.simple_spec`: the job, stone or wood, the amount; no conditions, subtypes, reactions)
     is made again, the new `dfllm:redo_<id>` first, then the old one removed; a wood order goes to stone when stone
     is plentiful (the carpenters never took it);
  3. else only reported.
  ORDER_STUCK (B) once per order: `order 41 ConstructDoor x5 stale: no job for 12 days (Masons: 1 shop, 5 jobs (0
  working), none from this order; 635 free boulders): re-entered in wood` (kern.log the same), `why` `stale: ...`,
  `dropped` 1 when made again. Never an order of a keep list (brews, meals, barrels), an EngraveSlab (BUG-061) or a
  standing order (FR-73).
- **The reason** names the jam when there is one (BUG-061) or the workshop's shop and job counts, and the free stone or
  logs. `inspect orders` carries the open `stale` records (id, days, left), `shops` and `jam`.
- BUG-042's cap is kept unchanged: a stale order counts as open, so the cap stays reached until the stale orders are
  gone; the switch to wood lets the carpenters finish them, DF removes finished orders and the cap frees itself.
- Config (`lint --config`): `economy.stale {days, wait_days, per_day, jobs_max}`.

## Note 10 (answer from the live evidence of BUG-042)
A table and a chair in the manager's office were enough: y471 winter d42 a chair and a table built in office 18631 let
the manager take ManageWorkOrders at once, unvalidated orders 112 -> 51, the brew orders 1250/1260/1261 validated
(`bugs/BUG-042-drink-falls-without-a-brew-order.md`, "Live confirmed"). No chest or cabinet was needed. The kernel
checks both pieces daily (`M.office_check`, `office.table`); nothing more is added.

## Not decided offline (the read-only live data that decides it)
- **Why DF made no job** for the 11 orders. At the next sighting read, before touching anything: the Masons workshop job
  list (`inspect orders` `shops`: jobs / working / blocked per workshop key; or Lua `building.jobs` with `job_type`,
  `order_id`, `flags.working`), the count of EngraveSlab orders and unengraved slabs (`inspect orders` `slabs`), the
  top cancel reasons of the day (`inspect workload` `cancels`), and the stale record of each door order (`inspect orders`
  `stale`). If the masons' slots hold the EngraveSlab jobs (BUG-061), the cause is settled; if they are empty with a
  boulder in reach, the order itself is the question (its `mat_type`/`mat_index`, `status.active`, `max_workshops`,
  `workshop_id`).
- **Whether `status.active` means a job exists.** The note reads "validated, active" with no job; df-structures only
  names the bit. Read it with `job.order_id` for a running order of another kind.

## Tests
`tests/lua/test_economy_b2.lua` (11 stone doors go wood after 10 days, 6 a day; no order with a job / a changing
amount / conditions / another frequency / unvalidated is touched, the control order is; no carpenters or logs: made
again, else only reported; a wood order made again in stone; the clock stands in SIEGE; a stale order behind a jam
names the jam), `tests/lua/test_economy_b2_wait.lua` (a planned door: 3 days instead of 10). Each new test fails on
f17e2b3.

Related: BUG-061 (probable cause), BUG-042 (door order cap, office), BUG-044 (the seal door), FR-73.
