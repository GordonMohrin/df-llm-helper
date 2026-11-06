# BUG-526 No verb to remove or cancel a manager order
Status: fixed (offline, live-untested)
Severity: medium (36 stuck orders and a jammed forge stayed for years; the player could only wait)
Found: 2026-11-06, Run 16c i3 Sealcertain y386 (`runs/run-16c/FR-BUGS.md` "Forge-Slots durch abgebrochene MakeWeapon-Jobs verstopft": no verb to remove or pause orders), Run 16b i2 (89 stuck orders)
Module: `lua/dfllm/economy.lua` (`M.verbs['orders.cancel']`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py` (`VERB_ARGS`, `VERBS`)

## Actual
`order.add` existed since FR-39 and `inspect what=orders` lists the open orders with their ids, but nothing took one off the list; only the kernel's own pruners (BUG-315, BUG-515, needs_cancel) did.

## Root cause
A missing verb: `act.order_remove` was reachable only from economy's own rules.

## Fix
Verb `orders.cancel {id}` or `{stuck: true}`, `force?` (any mode). `id`: one manager order (list: `inspect what=orders`); `stuck`: up to 40 of the orders the kernel's ledger calls stuck (`p.ostuck`, ORDER_STUCK). Safe: the supply orders (brewing, meals, barrels, raw fish: `keep_order`) are refused without `force:true`; jobs the order already made keep running (act.order_remove); a kernel-owned order (a tag in `p.orders`) is not entered again for `orders.backoff_days` and its stuck / cancel / stale records are dropped; an unknown id is an error. Reply `{removed, kept, ids}`; kern.log line per order. The listing is the existing `inspect what=orders` (no second verb).

## Tests
`tests/lua/test_bug526_orders_cancel.lua` (5: one order, argument rules, supply order + force, stuck=true leaves the others, kernel-owned tag freed), `tests/test_bug523_527_f33.py` (schema + route).

## Live check
`dfllm cmd inspect what=orders`, then `dfllm cmd orders.cancel id=<n>` (or `stuck=true`): the order is gone from the next `inspect what=orders`.
Open: no pause / resume of an order (act.order_suspend exists, no verb); `stuck=true` cancels at most 40 per call.
