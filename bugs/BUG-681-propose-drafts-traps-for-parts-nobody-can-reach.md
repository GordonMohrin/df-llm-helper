# BUG-681 `plan propose` drafts traps every year although every free trap part lies in the flooded level
Status: fixed (offline, live-untested)
Severity: medium (a traps project set aside 300 d, 'waits for trapparts x1', a lane drafted every year)
Found: 2026-11-10, Run 16a i1 Basementflew y470-y486 (FR-BUGS 'BUG traps: plan zeichnet traps@S1 jedes Jahr'; state stock.mfree 19, kern.log:4169-4332 'ConstructMechanisms x7: no job for 31-64 days (Mechanics: 2 shops ... 0 working)')
Module: `lua/dfllm/economy.lua` (`M.mech_reach`, `M.plan_mech`, state `stock.mfree` / `stock.mfar`), `dfpilot/plan.py` (`noparts_reason`), `dfpilot/schema.py`

## Actual
BUG-611 / BUG-628 leave the traps out of a draft when `stock.mfree == 0`. `mfree` was `M.mech_free()`: every TRAPPARTS item that is not forbidden / in a job / in a building / ...: 19 of them, in the fort whose Mechanics' shops lie in the flooded level z117. No citizen could take one, the traps project waited, the orders had no job, and propose saw 19 parts.

## Root cause
`economy.lua` `mech_free` has no reach test (and the lever flows of gate / seal / readiness read it unchanged); `plan.py` `noparts_reason` could not tell.

## Fix
- `economy.mech_reach(K)` -> reachable, out of reach: a free part on a tile with no walkable group (flooded, walled in) or on a group the citizens do not stand on (`snapshot.far` strict) is out of reach. `plan_mech` stores `rfree` / `ffar`; the state publishes `stock.mfree` = the reachable count (the raw count for an older save) and new `stock.mfar`. `mech_free` and `mech_state` (free, short, route) are unchanged: the lever flows read what they read.
- `plan.noparts_reason`: no free reachable part, `mfar > 0` and no order on the way (route not ordered / stone) is 'no trap part a citizen can reach: N free mechanism(s) lie out of reach'; propose then drafts no lane (BUG-628 path) and the gate warns.

## Tests
`tests/lua/test_bug681_mech_reach.lua` (3 free parts, 2 on far tiles: raw 3, reach 1 / far 2), `tests/test_bug679_684_f44_proj.py` (the reason, not with a part in reach or an order on the way; `traps.draft` leaves the lane out).

## Live check
`status` stock of a fort with parts in a flooded level: `mfree` 0, `mfar` N; `plan propose` notes 'BUG-628: trap lanes not drafted ... no trap part a citizen can reach'.

## Open
The cause (the parts lie out of reach) is inferred from the logs (mfree 19 beside 'no job' orders and a waiting trap); the item positions were not readable offline. The orders for new mechanisms still go to the Mechanics' shop that is cut off (BUG-654 names a cut-off shop type); `m.short` is not changed, so no extra order is made for unreachable parts.
Related: BUG-611, BUG-628, BUG-654, BUG-665
