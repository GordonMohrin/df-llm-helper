# BUG-203 Made-again orders and a project's piece orders were appended at the end of a queue whose jobs filled every shop
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F6; skeptic confirmed)
Module: `lua/dfllm/act.lua`, `lua/dfllm/economy.lua`, `lua/dfllm/runner.lua` (`act.workorder` (`spec.top`), `T.stale`, runner `orders`/`orders_first`)

## Actual
The core's door, bed and block orders stood at places 82-88 of 89 behind MakeTool/goblet/armor stand/cage jobs; `T.stale` made stale orders
again at the end of the list, which made it worse. Only a seal's orders went to the top.

## Fix
- `act.workorder` takes `top = true` (not sent to DF): the new order moves to the top of the work orders. `T.stale` uses it.
- runner: every project's quickfort piece orders move to the top (`order_top`), not only a seal's; while a seal is open (seal first) only
  the seal's do. kern.log `(seal first)` / `(project first)`.

## Tests
`tests/lua/test_act_supply.lua`, `tests/lua/test_runner_seal_first.lua`, `tests/lua/test_economy_b2.lua` (BUG-203). Each fails on bd27973.

## Live check
A placed bedrooms/workshops project in a fort with many library orders: kern.log `<id> <stage>: N manager orders moved to the top of the work
orders (project first)`; the work orders screen shows them first. A stale order made again stands first.
