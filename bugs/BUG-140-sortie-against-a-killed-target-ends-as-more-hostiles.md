# BUG-140 A squad.sortie whose target was killed ends as `abort more_hostiles`, not `dead`
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: high (wrong decision: the sortie's result is misreported, a dead target reads as a new threat)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/military.lua (`sortie_pass`)

## Actual
`squad.sortie` against 41878: squad A soldier 42224 killed the target (incident STRUCK_DOWN), and the next event was #32450
`sortie A ended: the picture is no lone harmless intruder any more` [phase=abort why=more_hostiles ticks=1201], no `dead`.

## Cause
`sortie_pass` tested the lone-harmless picture (`M.lone_of`) before the kill sortie's dead check. A dead target leaves the census, so
`reflex.lone_ids` answers `stale` (its scan lags one pass) or `group` (another lone harmless unit stays in sight). `group` ended the sortie
at once; `stale` after `so.nolone + dt >= 2 x SO_EVERY` ticks, and with military perf-demoted (x4) one pass covered 1,201 ticks.

## Fix
A kill sortie whose targets are all dead ends `dead` (why `killed`) first, right after the `held` check; the picture test asks only for the
living targets; the lag allowance counts looks (two in a row), not ticks.

## Tests
`tests/lua/test_bug140_sortie_dead.lua` (3, all fail on dec5132): the dead target with another lone unit in sight, one demoted look of
300 ticks after the death, one long stale look while the target lives.
