# BUG-881 A raise waits for the recall stream until the hostile is 30 tiles out; its pull is cancelled for walkers 8-25 ticks after it is queued
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17d i4 Girderroots y418 spring d39 (events #13415-#13639): ARRIVAL snatcher (popup), two cave dragons 92 tiles from O1, both bridges down, 22 citizens outside; 19 pulls and 18 cancels in the first 905 ticks, BREACH at T+900, 18 citizens dead (pop 50 -> 32).
Module: `lua/dfllm/gate.lua` (`holders`, `control`, `M.pull_late`, `closing_fast`, `track`, `can_reach`)

## Root cause
`holders()`: in SIEGE/BREACH the raise is forced (only units ON the footprint or on its path's first step hold it) only with a hostile within force_near 3, or within approach_near 30 and CLOSING after the raise was held approach_hold 300 ticks. Before that every walker within CROSS_REACH 13 steps holds it, and the recall stream of 22 citizens always has one there: no pull for 401 ticks, then pulls cancelled 8-25 ticks after queueing. The hostile needs ~7 ticks a tile (92 tiles = ~650 ticks), the pull and the move ~200-300 ticks: the first force came at +452, too late. A forced pull was cancelled again 9 ticks later for a unit on the footprint although its worker was still on his way.

## Fix
- Timed force: with the nearest visible hostile closing in (2 tiles in 60 ticks, `closing_fast`) and `d * RACE_FOE_TPT <= CLOSE_BUDGET` (640, ~80 tiles) the raise is forced at once (no approach_hold). A TIMED force still holds the pull for units ON or beside the footprint (BUG-587 standers beside it keep their own rule) and for walkers who can be on the footprint before the bridge has stopped moving, by the speed each was MEASURED at (`track`/`can_reach`: ticks a tile between looks; unknown = 9, a dwarf on the run): a citizen at 27 ticks a tile holds from 4 steps out, a runner from 12.
- Commit: a forced pull is not cancelled for units on the footprint while its worker is far from the lever (`M.pull_late`: within LATE_R 4 tiles, or position unknown; none = not late); only the last tiles of his walk count.
- The plain approach rule (BUG-587/775) is unchanged; its accepted risk (walkers let go within approach_near) stays.

## Tests
`tests/lua/test_bug881_886_ankunft.lua`: the arrival SIEGE TRAFFIC test (PEACE, 22 citizens streaming over O1/B1, 6 invaders 92 tiles from O1, real sense/threat/siege/gate: fails on main with O1 up at +2358, BREACH at +927 and four GATE_FORCED; passes: O1 +198, B1 +117, no crush, no BREACH, 3 pulls); the same with runners; `pull_late`. Regression: the siege traffic suites test_bug380/462/478/481/564/568/587/708/831_833 stay green.

## Live-Erwartung
Next invasion on any fort with a visible hostile 40-80 tiles out and citizens outside: the GATE lines say `forced` within ~60-100 ticks of the first sighting (not +450), O1/B1 reach 'up' before the first hostile is within 10 tiles of them, 2-4 pulls per bridge in the first 600 ticks (not 19), no `BREACH ... not up at T+900` from traffic. NOT promised: a raise against building destroyers (cave dragons break bridges anyway, SIEGE_DEEP says so), a raise with a hostile that appears closer than ~25 tiles (the lever latency does not fit), crush-freedom for walkers faster than measured (the approach rule's accepted risk).
