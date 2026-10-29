# BUG-225 ORDER_STUCK for a missing input or worker is still one event per order
Status: fixed (offline, live-untested)
Severity: low (wake noise)
Found: 2026-10-29, live round 4 (i-test3 Earthboat) and skeptic (BUG-205 residual)
Module: `lua/dfllm/economy.lua` (`T.ocheck`, `M.ws_stuck`)

## Actual
BUG-205 grouped only kind `workshop`. Events #2694-#2740: 12x `order 28x MakeX cannot run for N days: no bars:INORGANIC:IRON`
in one game month, earlier 9x `no rock`; only `report_per_day` (3 a pass) limited them.

## Fix
`T.ocheck` groups kind `input` and `worker` like `workshop`: key `kind:why`, one ORDER_STUCK per key at the end of the pass with
`d.n`, `d.kind` and up to 3 order ids in the text (`N order(s) cannot run for D days: why (order 1 Job, 2, 3, ...)`); a key with
one order keeps the old `order N Job cannot run ...` text. Again only with news (an order not told) after 7 days and 10 min
(`p.wsstuck`, util/cadence). Kind `jam` stays per order. The care.lua stressor count is not part of this package.

## Tests
`tests/lua/test_economy_orders.lua`: the BUG-225 test and the FR-01 slicing test (55 same-input orders -> 1 event, n 55); both
fail on 5e9e719.

## Live check
`dfllm events --type ORDER_STUCK` over a game month in a fort without iron: one `N order(s) cannot run ...: no bars:INORGANIC:IRON`
event with d.kind input and d.n = the order count, not one per order.
