# BUG-905 The quiet PEACE raise of B1 never comes: every unit within 20 tiles, soldiers at their station included, restarts its quiet window
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i3 Orangering (kernel b8160ba3, 25.11.2026), B1 85-87,64,142: ~35 `B1 up waits in PEACE: citizen/soldier 3-5 tiles from it, no walker near it for 645..2055 ticks needed` lines in game year 469, 0 raises; the return window lowers B1 for 600 ticks and it is never raised again, so B1 is DOWN when the alarms come (BUG-906..909). Diagnosis `leitung/neu10/DIAGNOSE-B1-2026-11-25.md`.
Module: `lua/dfllm/gate.lua` (`M.peace_busy`, new `M.peace_blockers`, `peace_free`, `M.peace_day`, `M.peace_wait`)

## Cause
`gate.lua` `M.peace_busy` (BUG-831) counted every living unit within `gate.peace_clear_r` (20) tiles of the footprint, standing or walking, soldiers at their station included (BUG-831 retry, i4 #1441). The comment at the `PEACE_R` constant and `config/reflex.json` promise 'but a soldier at his station'; the code did not do it (`M.at_station` was never asked). The squad station of i3 lies 4 tiles inside B1, so some soldier is always within 20 tiles, and one citizen on any path within 20 tiles restarts the window of max(600, measured lever latency 645..2055) ticks as well.

## Fix
`peace_free(e, cross)`: a unit does not make the quiet raise unsafe when (a) he is a soldier standing at his squad's station (`M.at_station`: within `STATION_NEAR` 2 tiles of a station order of his own squad) AND at least `M.PEACE_STAND_D` (3) tiles from the footprint (nearer ones stay held by the 1-tile margin and the movers rule of `holders`), or (b) he is farther than `M.PEACE_FAR` (8) tiles AND his walk path does not enter the footprint within `PATH_STEPS` steps (`M.crossers`). Units ON the footprint, anybody within 8 tiles, and anybody whose path enters the footprint still hold it (BUG-831..833 stay). `M.peace_blockers` returns all of them (nearest first), `M.peace_busy` the first; `peace_wait` and the pending-pull cancel use it unchanged. New: once per want, when a bridge has been wanted up in PEACE for a game day (`M.PEACE_DAY` 1200 ticks) GATE `state peace_stuck` names the blockers by kind and distance (`units`, `n`, `ticks`), from the wait and from the hold path (units on/beside it, movers near it).

## Cost (who can be locked out / crushed)
Nobody is locked out by this fix. Crush: a unit farther than 8 tiles that starts for the footprint only AFTER the lever has been pulled (nothing can cancel the pull then, the bridge moves ~100-300 ticks) can reach it while it moves: at 18 ticks a tile and a 300-tick move a citizen 15 tiles out is crushed (the original BUG-831 case; `tests/lua/test_bug831_833_peace_bridge.lua` 'BUG-905 cost'); at a dwarf's usual 24-27 ticks a tile 8 tiles take 190-215 ticks. A soldier at his station who steps onto the footprint while it moves is crushed (the BUG-831 retry case, test 'BUG-905 cost'); BUG-906 keeps stations 4+ tiles out. The fallback is unchanged: GATE_CRUSH_RISK, the bridge stays down in PEACE for `peace_lock_days` (3, doubled per risk).

## Tests
`tests/lua/test_bug905_909_b1.lua` (harness `tests/lua/b1_world.lua`, B1 3x1 footprint 50..52,40, station 51,44, lever latency 645 seeded; ticks from the first frame, the gate's first pass is at +612):
- four soldiers shuffling at the station (4-5 tiles out) and a citizen patrolling 15-20 tiles out: want +612, pull +1260 (= 648 after the want), B1 up +1341, 0 crushed;
- a citizen 4 tiles out walking onto it (sets off at +1000): crosses +1116, no pull until +1962 (a whole quiet window after he left the 8 tiles), up +2043, 0 crushed;
- a citizen standing 6 tiles inside keeps B1 down; GATE `peace_stuck` names `citizen 62 (6 tiles)` once after 1200+ ticks; a unit standing 14 tiles out does not hold (up), one 7 tiles out does (down).
`test_bug831_833_peace_bridge.lua`: the BUG-831 tests that pinned the old rule are rewritten (see their comments); the 'cost' tests document the price. All SIEGE traffic suites stay green.
On main (gate.lua / military.lua of b8160ba3) these tests fail (no pull in 2300 ticks).

## Live-Erwartung
i3 B1 (or any inner bridge whose station lies 4 tiles inside): after the `B1 up waits in PEACE ... soldier N` lines come a `B1 pull` and `B1 up` within ~700-1000 ticks of the want, with the squad standing at its station (kern.log `gate: B1 up N ticks after the pull was queued`); no `peace_wait` line names a soldier at his station any more; a citizen idling within 8 tiles still keeps it down and after one game day a single `GATE peace_stuck` line lists who (kind id (tiles)). NOT promised: that nobody is ever crushed by a unit that sets off after the pull is done (see Cost), and nothing about alarms (BUG-906/907).
