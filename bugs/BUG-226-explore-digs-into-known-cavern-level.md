# BUG-226 A placed explore digs into a cavern level the kernel already knows
Status: fixed (offline, live-untested)
Severity: medium (an A wake and a plug per shaft)
Found: 2026-10-29, live round 4 (i-test3 Earthboat, FRICTION-explore-cavern) and skeptic
Module: `lua/dfllm/runner.lua` (`work`, `Q.explore_cav`)

## Actual
The four y380 explores (s0b0..s3b0, depth 12, z135 -> z123) were placed at the first plan apply. s0b0 broke into a cavern at
46,77,123 (CAVERN_PLUG #2388); the runner put z123 into `manifest.caverns`. s2b0 started later with its depth unchanged and broke
into z123 again (BREACH_STOP #2620, PROJECT_BLOCKED A #2692). Nothing re-checked a placed, not started explore against the cavern
levels recorded after its placement (plan's fit_explore keeps applied builds as they are).

## Fix
`Q.explore_cav` runs in `work` before an explore's dig stage applies its first chunk: a `manifest.caverns` level inside the
stage's z-range cuts the shaft to stop one level above it (cells at or below the level dropped, the new bottom stair an up stair,
`params.depth` = anchor z - cavern z - 1, caches and the shaft record reset, kern.log info line). When fewer than 2 levels would
remain the explore is blocked `cavern_known` with one PROJECT_BLOCKED (A) naming `bp.cancel` (blocked_event's cadence marked, so
no second wake). The plan.py half (re-fit kept explores, one per year once a cavern is known) is not in this package.

## Tests
`tests/lua/test_runner_cavern.lua` (two BUG-226 tests), fail on 5e9e719.

## Live check
On a fort whose `manifest.caverns` names z123: a queued explore with its shaft through z123 logs
`<id> (explore): cavern level z123 known (manifest caverns): the shaft stops at z124 (depth N, was zM)` when it starts, its
designations end at z124, and no BREACH_STOP/CAVERN_PLUG follows for it.
