# BUG-624 Flux is a valid trade token (BUG-583) but the kernel never asks for it: the steel chain waits on flux for years
Status: fixed (offline, live-untested)
Severity: medium (steel orders and pig iron waited; the steel DECISION named the command, nobody sent it)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y426-y428 (`trade.want` held 12 kinds, no flux stone, with the steel DECISION open)
Module: `lua/dfllm/economy.lua` (`M.supply_wants`, `M.SUPPLY.flux_cap`, `plan_steel` `st.steel.missing`)

## Actual
`{"add":["flux"]}` was accepted by hand (BUG-583), but neither the kernel nor `plan propose` put flux into the want list when the smelter lacked it.

## Root cause
`economy.supply_wants` (the kernel's own caravan wants: mechanisms, stone, gems, logs) had no flux entry; `plan_steel` knew `missing = {'flux'}` and only raised the DECISION.

## Fix
`supply_wants` adds `{buy='flux', n}` while steel orders wait (`st.steel.n > 0`) and `plan_steel` found no flux stone (`st.steel.missing` holds 'flux'): two boulders per steel bar still to make, at least 2, at most `SUPPLY.flux_cap` (10). It goes away when flux stands or no order needs steel.

## Tests
`tests/lua/test_economy_reach.lua` (BUG-624: wants flux without flux stock, not with it)

## Live check
Trumpetrealms: with the steel DECISION open, the next caravan's want list (`inspect trade`) holds a boulder of a flux stone (limestone ... marble).
