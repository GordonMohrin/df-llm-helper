# BUG-845 'Needs logs' on a fort with 204 logs: no way to see why they lie where nobody walks, no way to give the Woodcutting labor
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank: DF 'Needs logs' for doors, buckets, cabinets, crafts, charcoal; 198 of 204 logs on tiles with no walk group; the players could not assign woodcutting (labor.set knew only carpenter).
Module: `lua/dfllm/act.lua` (`LABOR_SETS`), `dfpilot/schema.py` (`LABOR_SETS`), `lua/dfllm/economy.lua` (`M.wood_cancel`, census)

## Root cause
With the census counting unreachable logs as free, the treeless path (caravans asked for wood, autochop target, the wood floors) never started; no verb gave Wood cutting.

## Fix
The census is truthful (BUG-842), so i1 now has 0 usable logs and the existing treeless path follows. `labor.set woodcutter` (CUTWOOD) is a player verb. The 'Needs logs' kern.log line states the split (no walk group / another group / job / skipped) and points to `why items:logs --raw`. NOT done (no proof of the cause, never dig or channel near water): moving where trees are felled, an autochop burrow restriction (the code has none; the DFHack option is unverified offline). What the sample must show: tile type and liquid of the 198 logs (a tree-top or branch tile or water = logs fall where no unit can stand: restrict chopping to trees whose trunk tile is on the citizens' walk group), building / stockpile (a sealed stockpile?), group 0 vs a number (a walled-in area).

## Tests
`tests/lua/test_neu4_cancel.lua` (i1 census and the 'Needs logs' line), `tests/lua/test_neu4_cancel.lua` (woodcutter label), `tests/test_neu4_cancel.py` (labor.set woodcutter).

## Live-Erwartung
1. i1 kern.log 'DF cancels Make ...: Needs logs' names '198 without walk group'; `why items:logs --raw` samples 10 logs with tile type and liquid; the lead decides the felling fix from them.
2. `dfllm cmd labor.set unit=<id> labor=woodcutter on=true` works. NOT promised: logs on unwalkable tiles are not fetched; wood arrives by trade or new trees only.
