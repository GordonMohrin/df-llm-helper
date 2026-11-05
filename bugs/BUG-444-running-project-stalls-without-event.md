# BUG-444 A running project kept its runner slot 556 days without progress and without an event
Status: fixed (offline, live-untested)
Severity: medium (i3 Castletongs: aqshaft S1 556 days at 7 %, `inspect workload` 'queued behind 3 slot holders', `bp.resume` 'not set aside (it runs)')
Found: 2026-11-05, Run 16c i3 Castletongs y374-y380
Module: `lua/dfllm/runner.lua` (`Q.stall_scan`, `Q.idle_keep`), `lua/dfllm/aqshaft.lua` (`A.where`)

## Actual
`Q.idle_scan` (BUG-328) sets a project aside after `idle_days` without progress, but not one `idle_keep` exempts (an aqshaft that holds a level, the refuge drink, a seal in a siege, a mood or care project, supply in an emergency);
BUG-435's `stale_scan` only looks at set-aside projects. Such a project kept its slot for ever and said nothing.

## Fix
`runner.lua Q.stall_scan` (every run, PEACE): a project that is neither done, halted nor set aside and whose own progress (R.ps) is `runner.queue.stall_days` (60, 0 = off) old is announced:
PROJECT_BLOCKED (A) `why=stalled`, `idle` days, `parts` = the cause (the aqshaft's level and ring state `z113 dig, ring wall/new/new/new`, its `stall zN` text, what the stage waits for, why it is kept), `cmd` = `inspect workload`,
`bp.cancel` (only what is not built goes), for an aqshaft `bp sites aqshaft --fresh`; again every `stall_every` (60) days (R.sks). Announcement only: the project keeps its slot.

## Tests
`tests/lua/test_bug443_444_ring_stall.lua` (announcement, cadence, off, the project is not cancelled).

## Live check
A shaft that holds a level without progress: after 60 days `PROJECT_BLOCKED ... stalled: no progress for N d at l7.dig 60%: z113 dig, ring wall/new/new/new; ...`, again after 60.

Note: the announcement stamp lives in the runtime field `R.sks` (not `R.sk`, which is the skipped-tile counter behind `lost`); a stalled stage that later completes keeps its real `lost`.
