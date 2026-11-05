# BUG-493 Drills never count as done: B1 not up (the recall holds the raise), restore timeouts, and a pass that needs worn >= 90 in a fort without metal
Status: fixed (offline, live-untested)
Severity: high (P5 waited for the drill for 4 years in i4; 45 drills pulled everybody into Kern+ for nothing; R2 and the pop ceiling hung on it)
Found: 2026-11-05, Run 16d i4 Trumpetrealms y382-y387 ("Drill started (cmd drill ok), status drill never, Phase P5 wartet 4 Jahre") and i2 Roadvises ("Auto-drill scheitert 'bridges not down in time'"); runtime `r16d4-trumpetrealms-site97/events.jsonl` DRILL_RESULT #474-#6146 (read only)
Module: `lua/dfllm/drill.lua` (`measure`, `finish`), `lua/dfllm/gate.lua` (`holders`, `quiet_wait`), `lua/dfllm/readiness.lua` (`drills`, `state`), `lua/dfllm/runner.lua` (phase deliverable `drill`), `dfpilot/brief.py` (`drill_note`)

## Actual
45 DRILL_RESULT in i4, none passed. By failure: `worn<90` in 45 (worn 20-80 %, a fort with METAL SHORT), `up:B1`/`up:O1` in 42 (a bridge not up at the measurement), `slow:O1/B1` in 20 (raise over 900 ticks), `outside:N` in 19; none failed on the gear alone; `restore -1` ("B1,O1 not down (timeout)") in 4 (i2 more). Status showed only `drill never (auto: retry wait) [last auto drill 38d ago failed]`: neither why nor that the bridges were fine. P5's deliverable `drill` is `ready.drill_age >= 0` = a pass exists.

## Root causes
1. `gate.lua holders`: only SIEGE/BREACH timed their raise (`CROSS_REACH` 13 steps); DRILL held a pull for every unit whose path enters the footprint within `PATH_STEPS` (20), and a drill sends everybody home over B1 (civ alert on Kern+): the stream held the raise to T+900 ("B1 up waits for citizen ... walking onto it", "B1 not up by the drill's T+900: no late raise" in kern.log), `up:B1`/`slow:`.
2. `gate.lua quiet_wait`: the lowering of the drill's end (why `drill_end`) waited up to `QUIET_MAX` (2400) for a quiet ring, `drill.RESTORE_MAX` is 1200: `restore -1`, "bridges not down in time".
3. `drill.lua measure`: a pass needs `worn >= 90` (the only worn check of R2) and the fort had 20-70 %: no drill could pass, so `drill_age` stayed -1 for ever and P5 never met its deliverable even when the bridges worked.
4. DRILL_RESULT/status did not say which check failed.

## Fix
- `gate.lua`: DRILL is a timed mode (`TIMED_MODES`): walkers farther than 13 steps do not hold a raise (they cannot reach it while it moves, BUG-380 review); `M.QUIET_DRILL` (500): the lowering of the drill's end gives up the quiet window after 500 ticks and keeps the 1-tile margin.
- `drill.lua`: DRILL_RESULT carries `fails` (the list) and `mech` (1 when every failure is a gear one: worn, soldiers, military); persisted in `drill.last[].mech`. `readiness.state` publishes `ready.drill_mech_age` (age of the newest drill that passed or has mech 1; -1 none); the phase deliverable `drill` (runner) is met by `drill_age >= 0` OR `drill_mech_age >= 0`. The R2 pass (`drill_age`, worn >= 90) is unchanged.
- `brief.drill_note`: `[last auto drill 38d ago failed: up:B1, worn<90; bridges ok]`.
- Not changed: the retry back-off (a month, x2, at most a season), the pass rule.

## Tests
`tests/lua/test_bug492_493_traffic.lua` (4) DRILL recall stream: B1 up by T+900, nobody crushed (fails on the old rule), (5) the drill's end lowers within the QUIET_DRILL cap (fails with 2400); `tests/lua/test_bug493_drill.lua` (4): no gear -> `fails {'worn<90'}`, `mech 1`, `drill_mech_age >= 0`, `drill_age -1`; a bridge that never rises -> `mech 0`; a full pass sets both; `tests/test_bug493_drill_note.py` (3). `tests/lua/test_drill*.lua` unchanged and green.

## Live check
`dfllm status`: `drill never ... [last auto drill 2d ago failed: worn<90; bridges ok]`; `ready.drill_mech_age` in state; P5 leaves "waits for drill" after one drill whose bridges worked. In a drill with citizens coming home over B1: B1 up by T+900, `DRILL_RESULT restore` under 1200.
Open: a fort without metal still never reaches R2 (worn 90) by the drill; whether R2 should count that is a design decision (not changed).
