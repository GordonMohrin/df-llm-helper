# BUG-720 A seal wall tile held by a coffin: the seal stood `occupied` 40 days, the audit named the tile again, `seal at=audit` said 'nothing to close'
Status: fixed (offline, live-untested)
Severity: medium (the bypass the seal was placed for stays open; the runner slot is held)
Found: 2026-11-10/11, Run 16a i1 Basementflew y440-y441 (seal c1a1c7a48e 'Coffin 97,92,129 (a wall wanted)', audit `bypass: wall 97,92,129 floor (+more) -> 97,85,129` in every audit, cli.log `seal: nothing to close`)
Module: `lua/dfllm/runner.lua` (new `Q.occupied_cancel`, `M.CFG.occupied_days`), `dfpilot/cmd.py` (`audit_avoid`)

## Root cause
BUG-565 blocks a seal whose tile holds a building of another kind as `occupied` (never done), BUG-579 makes `audit_routes` file the tile under `jammed` so `seal at=audit` leaves it out ('nothing to close'). Nothing ever resolved it: the blocked seal stayed in the queue (parked after 30 d) and the AUDIT FINDING kept naming the same tile (`audit_avoid` held only fortcore tiles and finished seals), so no other tile of the route was ever offered.

## Fix
- `cmd.audit_avoid` includes the tiles of `seal_occupied` (PROJECT_BLOCKED why=occupied, not cleared by a later PROJECT_DONE): the finding names the next closable tile of the route (BUG-658 mechanism), else the route text.
- `Q.occupied_cancel` (PEACE only, one a run, `occupied_days` 3, 0 = off): a seal blocked `occupied` that long is cancelled (nothing of it stands, no undo); PROJECT_BLOCKED (A) why=occupied carries `d.parts` (the building and tile BUG-579 reads) and `d.autocancel`.

## Tests
`tests/lua/test_bug720_occupied_seal.lua` (3, one a siege traffic guard: in a SIEGE nothing is cancelled and no bridge, gate or lockdown behaviour is touched), `tests/test_bug720_audit_avoid.py` (2).

## Live check
PROJECT_BLOCKED with `autocancel` after 3 days, then the next audit's `bypass: wall` names another tile, `seal at=audit` places it.
Open: the coffin itself is not moved (its tile stays unwalled; if it is the route's only tile the finding falls back to the route text); a seal with some pieces standing is not cancelled (only `done == 0 and pend == 0`, as BUG-565).
