# BUG-083 A stale order that is made again loses its tag (the planner enters it a second time) and is made again for ever
Status: fixed in 8d23f4c (offline, live-untested)
Severity: medium (duplicate orders eat stone and masons' slots; an unrunnable order was entered, removed and entered again every
3 to 10 days with an ORDER_STUCK each time)
Found: integration audit I3 (2026-10-23), the combination of B2's stale pass (BUG-060) with the planner's order registry
Module: `lua/dfllm/economy.lua` (T.stale), `config/baseline.json`, `dfpilot/fairplay.py`

## Actual
`T.stale` makes a simple stale order again: a new order tagged `dfllm:redo_<id>` first, then the old one is removed. Two things
follow in the merged tree:
- the kernel's own orders (the piece orders `dfllm:piece_*`, the idle backlog `dfllm:idle_blocks`, `dfllm:idle_crafts`,
  `dfllm:slab`) are in `m.economy` `orders[tag] = id`. The removed id stayed there, so `live(p.orders[tag])` was false and the
  planner (backlog_pick, plan_leather, ...) entered the same order a second time beside the made-again one. The other removal
  paths (needs_cancel, no_rock) clear the tag and set a backoff; this one did neither.
- the made-again order has no record (`p.ostale` starts at the new id), so its clock restarts: an order nothing can run
  (no mason labor, no worker for the job) went stale again after `stale.days` (10; `stale.wait_days` 3 while a planned building
  waits for the piece) and was made again, with a new ORDER_STUCK, for ever.

## Cause
`economy.lua` T.stale (9bcb14f): `local ok = K.act.workorder(spec)` dropped the new order's id; `p.orders` and `p.ostale` were not
touched after `K.act.order_remove(e.id)`.

## Fix
- The tags that named the removed order name the new one (`p.orders[tag] = new id`), so the planner sees its order, its inputs
  (`p.meta`) and its amount as before.
- The new order's record carries `redo = n + 1`; `economy.stale.redo_max` (2, 0-20; `fairplay.ECONOMY_LIM`, baseline.json,
  CONTRACTS config paragraph) bounds the chain: past it the order is reported once (`only reported`, ORDER_STUCK) and left
  alone. A job in a workshop or a changed amount resets the record as before. `redo_max` 0 = never made again.
- Safety: nothing is removed that was not before; PEACE/RECOVERY only, `stale.per_day` as before; an old kernel state has records
  without `redo` (0).

## Not decided offline
Whether a made-again order at the end of the list is right for an order that sits at the front (a seal's door order moved to the
top by the runner loses its place; the wood re-entry `order_material` keeps it and comes first when logs and carpenters exist).

## Tests
`tests/lua/test_integration_i3.lua` (fails on 9bcb14f): the tag follows the made-again order twice, the third time the order is
reported once and no order is made.
