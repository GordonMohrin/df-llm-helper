# BUG-914 `inspect what=workload key=tools` shows the last complete reading, with its age and the census error counter
Status: fixed (offline, live-untested)
Severity: medium (false 'no axe / no pick' diagnoses; plan_axes and the trade wants could follow them)
Found: Run 17 i1 Diedplank (readings y375, y381, y383, y421 d55): 'axe 0, pick 0' while 14 axes and 23 picks existed (later readings: axe 14, free 12; pick 23, free 20); the agent's FR-BUGS line 260 calls it 'veralteter/leerer Lesestand'. The cause is NOT proven (diagnosis): the census runs in slices under pcall (`census_slice`), an unreadable item is only counted in `cs.errs`, a resume or reload may publish an empty or partial census wholesale.
Module: `lua/dfllm/economy.lua` (`M.tools_hold` l.1537, `publish`, `M.tool_counts` l.17114, `M.TOOLS_HOLD_DAYS`)

## Fix
`publish(K, c, a, errs)` calls `M.tools_hold`: a pick or axe class that reads 0 from a census with unreadable items (`errs > 0`) or from an empty tool census (no pick and no axe at all) while the last COMPLETE census (errs 0, persisted `m.economy.toolsl`, survives a reload) held some keeps that reading (all `w_<class>*` counters, the item lists) for at most 3 game days (`M.TOOLS_HOLD_DAYS`); a fort that really lost its tools shows the zero after that. `inv.cerrs` (this census' unreadable items), `inv.tools_kept`, `inv.tools_age` (ticks) are published; `M.tool_counts` (inspect workload with key=tools, and the workload data) adds `errs`, `kept`, `age`. A complete census replaces the stored reading (written at most every quarter game day).

## Tests
`tests/lua/test_bug910_915_holz.lua`: 14 axes / 23 picks read, items made unreadable: the reading stays with kept=1, age, errs>0; readable again with 12 axes: 12, kept 0; unreadable for 4 days: zeros; a fort without axes: zero stays.

## Live-Erwartung
`dfpilot cmd inspect what=workload key=tools` on i1 shows `errs`, `kept`, `age` beside the counts; `axe 0` never appears while the last complete reading (within 3 game days) had axes. If a zero shows with `errs > 0` the counter names a failing census (next diagnosis: kern.log `census: N unreadable items (...)`); if it shows with `errs` 0 the cause is not a failed item read.
