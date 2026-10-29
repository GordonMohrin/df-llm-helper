# BUG-274 refuge hatch open 619 days, 'no builder has taken it', no cause named, never placed again
Status: mitigated (offline, live-untested): cause named, root cause open
Severity: high (refuge_trust R0 blocked for two years; the refuge stair stayed open)
Found: 2026-10-29, Run 15 Earthboat (y373-y375), fix6-runner-seal
Module: `lua/dfllm/runner.lua` (`Q.wait_why`, `Q.cls_of`, `stuck_event`, `Q.stuck_replace`); `dfpilot/schema.py` SEAL_STUCK `why`

## Actual
seal y373s1b0 (at=refuge): `hatch 55,82,133: job 8095 not suspended, no builder has taken it`; 9 idle dwarves;
`inspect workload` construction.blocked empty. Root cause not proven offline (item reach, burrow or labor); the kernel named no cause
class and nothing ever placed the hatch again.

## Fix
SEAL_STUCK carries `d.why`, the cause in one word: unreachable (no citizen's walk group at the piece or beside it), confined
(civil alert on or a reflex lockdown), no item (buildingplan), suspended (suspendmanager/DF), no builder, building, not placed; the
wait text adds `N items attached` for a job nobody takes. A door or hatch of a stuck seal (or closure) whose job no builder takes
2 x `stuck_days` after its clock stopped is removed (quickfort undo) and placed again (a fresh building and job), once per piece,
in PEACE without a lockdown; the stuck clock starts again (kern.log `removed and placed again (once)`). Not built: a hatch is not
turned into a wall + door (the stair would be cut), a door still goes to the BUG-044 wall first.

## Tests
`tests/lua/test_runner_seal_fix6.lua` `BUG-274 ...` x2 (fail on 2b9c009).

## Live check
Earthboat: `dfllm events --type SEAL_STUCK`: d.why and d.wait of the refuge hatch; 6 days after the clock stopped kern.log
`hatch 55,82,133 open N days, its job taken by no builder ...: removed and placed again (once)`; whether the fresh job is taken. If
not, read-only: the job's items (item position and walk group), the builders' burrows, labors (ARCHITECT / the material's labor).
