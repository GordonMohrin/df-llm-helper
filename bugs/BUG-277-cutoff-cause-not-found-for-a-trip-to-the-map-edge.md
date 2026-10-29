# BUG-277 CUTOFF 'cause not found' for a founder on a trip to the map edge (four times, never a death)
Status: fixed (offline, live-untested)
Severity: low (noise: an A wake for nothing, four times)
Found: 2026-10-29, Run 15 Earthboat (y372-y374), fix6-alarm-noise
Module: `lua/dfllm/seal.lua` (`M.trip`, `M.cut_confirm`, `commit_audit`, `job_audit`)

## Actual
`runs/run-15b-earthboat/FR-BUGS.md`: #36 CUTOFF (spring d65) 'citizen 26275 at 3,126,141 on group 5168', later #741 (unit 26272
at 1,126,141) and #814 (unit 26277 at 4,126,141): always a founder, always the same spot at the map edge, every time 'cause not
found', never a death. `inspect what=unit key=26275` at d77: pos 96,94,140 with the others, job none; `inspect what=reach`: all 7
citizens on one group, cut 0.

## Cause
`commit_audit` emitted CUTOFF on the first audit whose re-read (BUG-021) still saw the rise, with no look at the unit's job and no
second read: a dwarf gathering or hunting at the edge of the map stood on a walk group of his own for a few hours.

## Fix
`M.cut_confirm`: a citizen whose current job takes him outside (`M.TRIP_JOBS`: GatherPlants, FellTree, Hunt, HuntVermin, Fish,
CatchLiveFish, CatchLiveLandAnimal, CollectSand/Clay/Webs, GatherHoney; read from `unit.job.current_job`, read only) does not
count; only trips: no CUTOFF, kern.log 'no CUTOFF: ... on a job outside (id:job)' once per set. With a closer found (blame) CUTOFF
comes at once as before; with 'cause not found' it is held (`mem.cut_pend`, kern.log 'CUTOFF held for an audit a day later') and the
class keeps its old count, so the next audit reads the rise again (a held one is never skipped as 'periodic, unchanged'); an audit a
game day or more later that still sees it emits CUTOFF ('cause not found (N d)'); a rise that is gone drops the hold.

## Tests
`tests/lua/test_siege_strand_noise.lua` `BUG-277: ...` x3 (fail on 2b9c009).

## Review
A rise made only by a trip citizen re-reported citizens cut off long since (they were the only non-trip ones off the
stock): `cut_confirm` now counts a rise only when more non-trip citizens than the class's old count are off it (test:
"one citizen cut off long since ... no second CUTOFF").

## Live check
At the next trip to the map edge: kern.log 'seal: CUTOFF held for an audit a day later: 1 citizen off the food group' and no
CUTOFF; or 'no CUTOFF: the 1 citizen off the food group is on a job outside (26275:GatherPlants)'. A real cut without a visible
cause still comes, one audit later, as 'cause not found (N d)'. If the edge spot gives CUTOFF again, read the unit's
`job.current_job.job_type` (read only) and add its name to `M.TRIP_JOBS`.
