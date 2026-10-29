# BUG-205 ORDER_STUCK came once per order whose workshop is missing (x45 in 2 months); care logged an empty stressor line weekly
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F7-spam; skeptic confirmed)
Module: `lua/dfllm/economy.lua`, `lua/dfllm/care.lua` (`T.ocheck`, `M.ws_stuck`; care weekly stressors)

## Actual
Every imported order of a missing Farmer's Workshop, Loom, Quern, Glass/Wood Furnace or Still got its own ORDER_STUCK. kern.log had
'top stressors this week: ' with an empty list 41 of 41 times (care.lua logged it with no check).

## Fix
- ORDER_STUCK kind=workshop is one event per missing shop type at the end of the pass, with the count (`d.n`, first order in `d.order`,
  `d.why`); again for that type only with an order not told yet, after 7 game days and 10 min (`p.wsstuck`). It counts as one of
  `report_per_day`. Other kinds are unchanged.
- care logs the weekly stressor line only when the week had stressors.

## Tests
`tests/lua/test_economy_orders.lua` (BUG-205; FR-01's report_per_day test uses an input reason now), `tests/lua/test_care.lua` (BUG-205). Each fails on bd27973.

## Live check
A fort with imported orders and no Loom: one `ORDER_STUCK ... N order(s) cannot run for D days: no Loom workshop` per type; kern.log has no
empty `top stressors this week:` line.
