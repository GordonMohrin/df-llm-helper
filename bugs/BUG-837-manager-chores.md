# BUG-837 the manager spins, processes plants or carries water instead of validating; why says 'no cause found'
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Run 17 i1 Diedplank (cli.log 938/1166/1181 'order 438/457 MakeBarrel: not_validated ... he works as a farmer'; 457 unvalidated 21 days; manager jobs SpinThread, HarvestPlants, Eat, ProcessPlants; 'manager Ducim: job SpinThread; 0 orders unvalidated, no cause found') and i2 (manager Kadol works as carer, GiveWater / GiveFood)
Module: `lua/dfllm/economy.lua` (`M.manager_farm_off`, `M.MGR_OFF`, `M.manager_facts`), `lua/dfllm/jobwhy.lua` (`J.order`)

## Root cause
BUG-547 switched off only Farming; i1's manager spun thread and processed plants, i2's carried water (confirmed by the jobs in cli.log). `manager_facts` named only the farmer jobs, so 'no cause found' stood for any other chore.

## Fix
`M.MGR_OFF`: Farming, Herbalism, Spinning, plant processing and giving water go off for the manager (acts `farm`, `herb`, `spin`, `process`, `feed_water`, off only) while orders wait unvalidated, once a day; `manager_facts` names any other chore ('he works as X while N orders wait'), `jobwhy` the same from the manager's current job for an unvalidated order.

## Tests
`tests/lua/test_bug544_547_stone_manager.lua` (all five labors off, a Dig chore named), `tests/lua/test_bug834_838_brew_chain.lua` (an unvalidated order names GiveWater).

## Live-Erwartung
1. kern.log `manager NAME (unit N): labors off (...)` when orders wait; `why order:ID` on an unvalidated order names the manager's job.
2. New supply orders (MakeBarrel) are validated within 2 game days (`inspect manager` unval 0).

## NEU3 (diagnostics first)
This cure acts on a cause that was never confirmed live (two verifiers rejected it). It is now behind `economy.diag.mgr_chores` (default **false**, config/baseline.json): with the switch off the fort behaves as before this bug (only the Farming labor goes off for the manager; the query still names his chore). The reporting part (texts, `dfpilot why`) stays on. Turn it on only after `inspect what=raw` / the kern.log stall line named this cause (docs/v2/NEU3-diagnose.md, BUG-839, BUG-840).
