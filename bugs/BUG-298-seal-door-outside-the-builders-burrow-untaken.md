# BUG-298 a seal door outside the builders' burrow is never taken
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/economy.lua` (M.burrow_out, build_state), `lua/dfllm/runner.lua` (Q.stuck_replace), `lua/dfllm/util/contract.lua` / `dfpilot/schema.py` (act burrow_tiles for runner)

## Actual
Run 15c Inkintense y374-y376: SEAL_STUCK #1487 / PROJECT_BLOCKED #1500 `door 92,99,133: job 94401/95916 not suspended, no builder has taken it`, also in round 1, with 8-10 idle dwarves; the door lies outside Kern+ (y 30-73). The re-place of BUG-274 (`removed and placed again (once)`) did not help. Root cause: economy.lua build_state only said `no builder has taken it` (8707); nothing looked at the burrow the builders keep to, and nothing could widen it for the job.

## Fix
economy.burrow_out (read-only, alerts and burrows screens): a civil alert on whose burrows all lack the tile, or most free adult citizens assigned to burrows that all lack it -> build_state `rec.burrow`, `rec.bwhy`, and the line `...: outside the burrow Kern+ (N of M free citizens assigned to it)` / `(civil alert on)` (SEAL_STUCK d.wait, PROJECT_BLOCKED parts, kern.log). runner seal first (PEACE, no lockdown, 2 x stuck_days): that burrow takes the piece's own tile only (review: a perimeter door's outer neighbours stay out of the burrow a civil alert keeps citizens in; act.burrow_tiles, the burrows screen's brush), once per piece, then stuck_days of waiting before the BUG-274 re-place.

## Tests
`tests/lua/test_fix10_economy.lua` (burrow_out), `tests/lua/test_runner_seal_fix10.lua` (the widening and the re-place after it). Fail on 05dc764.

## Live check
`dfllm cmd inspect what=projects` / SEAL_STUCK for c1a18844987fd71b01: the wait names `outside the burrow ...` if that is the cause; kern.log `seal first: ... outside the burrow X its builders keep to (...): 1 tiles added to it`, then a builder takes the door. If neither cause shows, the untaken job has another reason (read the job's items and the door tile's shrub `92,99,133 shrub` in ready.ents).
