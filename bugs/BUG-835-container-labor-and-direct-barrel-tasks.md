# BUG-835 MakeBarrel orders got no worker: nobody was known to hold Carpentry and the manager path was dead
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-24, Run 17 i2 Whirledrampart y485 (order 5745 MakeBarrel x40, job 1430329 'none worked' from tick 195.93M for 54+ game days, 'the labor this job needs is not known; the inputs lie free'; labor.set furniture x5 (HAUL_FURNITURE, not carpentry) changed nothing) and i1 Diedplank (orders 437/438/457 MakeBarrel 'not_validated', manager works as farmer; 110 'Needs logs' cancels with 183 census logs)
Module: `lua/dfllm/economy.lua` (`M.cx_labor`, `M.cx_direct`, `M.CX_LABORS`, `plan_contx`), `lua/dfllm/act.lua` (`A.LABOR_SETS`, `A.WS_TASK`)

## Root cause
Confirmed: the act `labor_set` had no Carpentry (`furniture` = HAUL_FURNITURE) and no log line counts CARPENTER holders; the only container order is a manager order (`dfllm:barrelx`), which needs a validating manager (i1: a farmer / carer) AND a holder. The manager bypass (BUG-231) covers chairs, tables, doors, beds, blocks only, not barrels. NOT confirmed: who held CARPENTER on i2 at that time and why the job went unworked.

## Fix
- `A.LABOR_SETS` gains `carpenter` and `stonecraft` (on only); `M.cx_labor` keeps `CX_HOLDERS` (3) adult non-soldier citizens on CARPENTER (STONE_CRAFT for the rock-pot path), one more per day through `labor_assign` (idle first, best skill).
- `A.WS_TASK.MakeBarrel` (wood): `M.cx_direct` puts up to `CX_DIRECT` (3) MakeBarrel tasks on the Carpenter sheet through `act.ws_task` (no manager, no validation) once the container stall is 2 days old, minus the MakeBarrel jobs already queued, one batch a day; a kern.log line per batch.
- Both run from `plan_contx` once a day while `p.contx` holds.

## Tests
`tests/lua/test_bug834_838_brew_chain.lua` (container stall: `labor_set carpenter` on citizens, MakeBarrel `ws_task` calls in batches of 3; `A.LABOR_SETS` / `A.WS_TASK` entries), `tests/lua/test_bug546_547_acts.lua` (message).

## Live-Erwartung
1. After a container stall line, kern.log `Carpentry labor on for unit N` (up to 3 holders) and `N MakeBarrel tasks on the Carpenters sheet at ID`.
2. Within 5 game days a MakeBarrel job at the Carpenters has a worker (`dfpilot why order:ID` says working) and `barrels` in the census rises.
3. If tasks are added but never worked, `dfpilot why job:ID` names the holders (BUG-836): that is the next blocker (burrow / busy / 'Needs logs').
