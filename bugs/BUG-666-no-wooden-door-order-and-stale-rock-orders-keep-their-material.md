# BUG-666 The only door order is "Make rock door" with 0 usable stone, 99 logs and no verb for a wooden door
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y438: `inspect what=orders` lists one door order, 'Make rock door' (371 days old, cancel 'Needs non-economic hard stone'); seal doors 'waits for door x1 (0 free, 2 ordered)' for days; the player found no cmd verb for a wooden door
Module: `lua/dfllm/economy.lua` (`wood_orders`, verb `order.add`, `M.hard_report`), `dfpilot/schema.py`, `dfpilot/wake.py`

## Actual
Stone 0 usable, 99-114 logs, a Carpenter's workshop, and the door stayed a rock order; the DECISION said 'wood serves doors' but named no way to order one.

## Root cause
- `economy.wood_orders` (the daily rock -> wood pass) skipped every order `T.stale` had switched or made again (`M.stale_mark`, BUG-224) even when no stone is free at all: such an order can only run in rock and never does.
- `order.add` had `material_category` only: the wooden form of a job was a list (`material_category: ["wood"]`) nobody found; the question gave no command.

## Fix
- `wood_orders`: with no free stone a made-again order is re-entered in wood too (the budget and floors are unchanged: the existing test 'logs already promised to wood orders' holds).
- `order.add` takes `mat: wood | rock` (wood = `material_category [wood]`, rock = `material INORGANIC`), refused together with `material` / `material_category` (Lua verb and `schema.py`). The `no_hard_stone` question carries `dfllm cmd order.add '{"job":"ConstructDoor","amount":4,"mat":"wood"}'` while logs are in stock; `wake.no_hard_stone_hint` says it.
- The seal door itself already took the wood route (`piece_route` gives 'wood' with Carpenters and logs); that stays.

## Tests
`tests/lua/test_economy_orders.lua` (verb), `tests/lua/test_bug665_668_stone_wood.lua` (stone 0 re-entry, made-again order with and without free stone, question command), `tests/test_bug665_668_f43_stone.py`.

## Live check
A fort with 0 usable stone and logs: kern.log 'order N ConstructDoor xM: rock -> wood'; `dfllm cmd order.add '{"job":"ConstructDoor","amount":2,"mat":"wood"}'` makes an order with the wood material class in `inspect what=orders`.
Open: a fort with no Carpenter's workshop still waits (the manager bypass adds workshop tasks only at a built shop).
