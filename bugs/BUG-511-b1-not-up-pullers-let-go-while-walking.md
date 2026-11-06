# BUG-511 "BREACH: B1 not up at T+900 (GATE_FAIL)": the lever pullers were let go while still walking, chosen only at the SIEGE, and 45 tiles from the room
Status: fixed (offline, live-untested)
Severity: high (0 dead in y405, but B1 never rose in 1,302 ticks; the same pattern opened the y406 siege, BUG-510)
Found: 2026-11-06, Run 16a i1 Basementflew y405 spring d11-d17 "Invasion 3" (FR-BUGS "Invasion 3 ... GATE_FAIL slow"); runtime `r16a5-basementflew-site97/events.jsonl` #4950-#4990 and `kern.log` ticks 163694133-163696900 (read only)
Module: `lua/dfllm/gate.lua` (`pullers_step`, `fill`, `arrive_allow`, `puller_mode`, `holders`)

## Actual
- #4950-#4953 tick 163694133 INVASION, reflex lockdown (alert Innen+), "B1 up held for 19 civilians on its attack side" (the BUG-338 hold, 496 ticks); mode stays PEACE until #4958 tick 163694625 (SIEGE_START), "B1 up no longer held (after 496 ticks)".
- kern.log 163694625 "lever pullers dfllm-levers = {26923,26830} (SIEGE)"; 163695233 "= {27027,26996} (SIEGE), let go 26923:away,26830:away" (608 ticks later); 163695833 "= {26648,26778}, let go 27027:away,26996:away" (600 ticks); 163695931 "= {} (BREACH)". Three pairs in a row, none arrived: the citizens were 40+ tiles from the lever room (levers 36-37,97,129; population at x 78-100), a walk of 400-500 ticks after their current job.
- 163695533 "B1 not up at its deadline, pull under way, another lever next; 390 ticks more", #4978 GATE_FAIL "B1 not up after 1302 ticks, 43 s (slow)", #4979 SIEGE>BREACH. No "pull taken" line before.
- 163696453 "1828 ticks into the BREACH only 0 of 19 soldiers stand at their stations (equip 10 ...)": the squads are ordered again and 163696532 "B1 up waits for soldier 26614 walking onto it in 13 steps (squad 100 on its way to its station 38,101,129)", i.e. a second hold from the soldiers' march over B1 (the station lies 4 tiles behind B1: footprint 42,100-102, station 38,101,129).

## Root causes
1. `gate.lua pullers_step` / `PULLER_ARRIVE` 600: a puller not on the room's tiles 600 ticks after the assignment is "away" and replaced by the next nearest citizen, whatever his distance. 45 tiles take 400-500 ticks plus the job he finishes first; each replacement restarted the clock with another far citizen: nobody ever stood at the levers, nobody took the pull.
2. The pullers were chosen at the SIEGE (`PULL_ROLES` by mode), 492 ticks after the arrival lockdown had already wanted B1 up.
3. (BUG-510) a tame animal and (known, round 31 "Not done") the soldiers' march over B1 hold the raise; the march is not changed here.

## Fix
- `gate.lua`: `arrive_allow`: the allowance to reach the room is `max(PULLER_ARRIVE, PULLER_BASE 300 + PULLER_STEP 12 x the distance at the assignment)`, at most `PULLER_MAX` 1,800 (`fill` records the distance, z counts double as in the ranking); a puller who is close and does not come is still let go at 600.
- `gate.lua fill`: a citizen already standing on the room's tiles is the first choice (he was ranked behind every citizen inside Kern+ because the room lies outside it: the +1000 rule).
- `gate.lua puller_mode`: in PEACE/ALERT a reflex lockdown that wants the gates up (`lock_why`) assigns the pullers like a SIEGE (the lever rooms are in the lockdown's alert list already: `gate.rooms` is mode-free outside BREACH); released with the lockdown.
- `holders` (BUG-510): animals no longer hold.

## Tests
`tests/lua/test_bug511_pullers.lua` (3, lever-room world of test_gate_pullers): far pullers (49 tiles, walk 800) are not replaced at 600 and a stuck one is let go at 300 + 12 x 49 = 888; a near stuck puller is still let go at 600; an arrival lockdown in PEACE (raiders not in sight) assigns the two pullers within the first frames and they stand in the room (the first and the last fail on the old code); `test_gate_pullers` (13) unchanged; `tests/lua/test_bug510_513_siege.lua` (SIEGE traffic with soldiers, citizens, animal).

## Live check
kern.log of an arrival: `lever pullers dfllm-levers = {..} (SIEGE)` within the first 150 ticks of the lockdown, no `let go ...:away` for pullers still walking, `B1 pull taken N ticks after queueing` before T+900.

## Open
The soldiers' march over B1 (squad stations behind the bridge, `squad_note` "on its way to its station") still holds a raise while it lasts; in BREACH no pullers are assigned to an inner bridge's room (`PULL_ROLES.BREACH` = core only, by design: an attacker-side room would draw civilians out of the refuge).
