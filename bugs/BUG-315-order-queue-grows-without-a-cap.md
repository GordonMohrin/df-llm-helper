# BUG-315 the work order queue grows to 194 with stuck duplicates and no cap
Status: mitigated (offline, live-untested): prune and cap built; the cause of the repeated gear orders is a hypothesis
Severity: high
Found: 2026-10-29, Run 15 Drillchamber (FR-BUGS Runde 1/2, next_round_notes)
Module: `lua/dfllm/economy.lua` (M.order_prune, M.mood_top, live, scan_orders, T.ocheck, T.orders), `config/baseline.json`, `dfpilot/fairplay.py`

## Actual
`inspect orders`: 192 open, 95 stuck (y376), 190/73, 194/73 (y377). ORDER_STUCK `28 order(s) cannot run: no
bars:INORGANIC:BISMUTH_BRONZE (order 290 MakeAmmo, 337, 338, ...)`, `15 ... no bars:INORGANIC:IRON`; kern.log `order
dfllm:gear_gloves x1 (gear)` 28 times, every 1-2 game days within one boot (also gear_head x34, gear_body x22, fish x28). The
mood's bag (435) and charcoal (437) orders did not run in 30 days; a third mood dwarf died.

## Root cause
(1) Nothing capped or pruned the queue: the stuck pass only reports (T.ocheck), the stale pass handles orders without
conditions, the "Needs" pruner needs cancels. (2) Hypothesis for the repeats: `live()` / `scan_orders` (economy.lua:1234, 1341)
count an own order as open only while `amount_left > 0`; DF counts amount_left down when it hands out the job, so while that job
waits (or cancels and the amount comes back) the planner sees no open order and enters another. Not provable offline (no order
list was saved). (3) Mood orders were made at the end of the queue.

## Fix
- M.order_prune (daily, end of T.ocheck): one-time orders stuck `stuck_days` or more with the same job, item subtype, material
  and reason keep one (the tagged one, else the oldest), the others are removed; above `orders.cap` (120) open orders the longest
  stuck past `prune_days` (30) go too; at most `prune_per_day` (30) a day. Never pruned: piece jobs (doors, hatches, furniture the
  planned buildings wait for), blocks, coffins, slabs, mechanisms, chains, buckets, cages, the glass/cloth/leather chains, meals,
  reactions, and the tags of pieces, redo, mood, drink/food, standing, care and the player (`dfllm:cmd`). A removed own order clears
  its tag and waits `backoff_days`. kern.log `order queue: N of M open orders removed ...`, one ORDER_STUCK (B, kind prune).
- An own order at amount 0 whose job is still in a workshop (orderfix shops.by_order of the last daily pass) counts as open.
- While a strange mood wants a material (care's need), the orders of the sand, bag, charcoal, glass, thread, cloth and tanning
  chains are made with `top` (first in the work orders).
- Config `orders.cap / prune_days / prune_per_day` (lint --config ranges).

## Tests
`tests/lua/test_fix11_builders.lua` `BUG-315 ...` x2 (fail on 9ef2ccb). The amount-0 rule has no own test (it depends on DF's
amount_left behaviour that is not known offline).

## Live check
Drillchamber after the load: kern.log `order queue: N of 194 open orders removed (stuck duplicates, above the cap of 120)`, a day
later `inspect orders` below ~150 and falling; `order dfllm:gear_gloves` no more than once per real need. Read-only, if gloves
repeat again: the order list's amount_left of the newest gear_gloves order and the forge's job list (job.order_id).
