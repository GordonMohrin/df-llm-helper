# BUG-729 One far hostile flaps the civ alert and ALERT_START / ALERT_END; far water animals hold ALERT at 100 t/s; the PREDATOR default came after the kill
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y480-y490 (`act.civ_alert` true / false five times in 20 real seconds for ONE visible enemy 30-45 tiles away, ALERT_START / ALERT_END every ~3 game days); Run 16c i3 Doorwings y372 (alligators / hippos at the river 24-60 tiles from the citizens: ALERT, clock 100 t/s); Run 16c i3 Wallfree y373 (a smilodon struck citizen 26523 down while its PREDATOR waited for the 60 s ack default)
Module: `lua/dfllm/siege.lua` (`alert_wanted`, `alert_cooling`, `go`), `lua/dfllm/sense.lua` (hostile scan), `lua/dfllm/reflex.lua` (`ack_step`, `pred_close`)

## Root cause
- siege.lua `alert_wanted`: the civ alert went on at <= 30 tiles of a citizen outside, off 600 ticks after the hostile was beyond 40: a hostile pacing along the line toggled it every ~700 ticks. `decide`: PEACE -> ALERT on any `a.hostile`, ALERT -> PEACE after 1,200 calm ticks: a hostile blinking in and out of sight started a new ALERT each time.
- sense.lua: a wild beast on the citizens' walk group that stands in or beside water counted as a hostile (threat.counts: within REACH of a bridge, or within 40 of a citizen), however far from every citizen.
- reflex.lua `ack_step`: every PREDATOR waited `ack_timeout_s` (60 real seconds = 6,000-18,000 ticks at 100-300 t/s) for the player's ack before its lockdown default, also one standing beside a citizen.

## Fix
- siege: `CIV_MIN_ON` 1,200 (a civ alert stays on that long), `CIV_REARM` 1,800 (once off it sounds again within that time only for a hostile within `ALERT_CIV_ON // 2`), `ALERT_REENTRY` 3,600 (after an ALERT ended a hostile not within `ALERT_CIV_ON` of a citizen outside or `ALERT_O1` of O1 does not start the next ALERT; a siege, an invader inside, a near hostile do at once). `st.civ_on`, `civ_off`, `alert_end` persist.
- sense: `WILD_WATER_NEAR` 20: a wild beast (no invader, great danger, undead, building destroyer, killer mark) in or beside water, outside Kern+ and farther than 20 tiles from every citizen is water wildlife: `census.h.wfar` / `wfar_d`, no hostile; `census.w` and WATER_PREDATOR keep watching it.
- reflex: `PRED_NEAR` 15, `PRED_NEAR_S` 10: a PREDATOR whose unit is inside Kern+ / past B1 or within 15 tiles of a citizen gets its lockdown default after 10 real seconds; a farther one keeps `ack_timeout_s`.

## Tests
`tests/lua/test_bug729_alert_hysteresis.lua` (4, one a siege traffic test: an army at O1 right after an ALERT ended is a SIEGE at once, O1 and B1 up, the civ alert sounds once in the SIEGE, no BREACH, no double pull); `tests/lua/test_bug729_far_water_beast.lua` (2); `tests/lua/test_bug729_predator_quick.lua` (3, one a siege traffic test: an army at O1 plus a predator beside a woodcutter, the quick default fires, SIEGE with O1 / B1 up and held, no BREACH, no pending violation).

## Live check
`commands.log` shows no more than one `act.civ_alert true` per ~1,200 ticks for one far enemy; ALERT_START at most every 3,600 ticks for it; `census.h.wfar` > 0 beside river animals with no ALERT; LOCKDOWN 'unacked for 10 s' for a predator beside a citizen. Open: a hostile that is near and far in turns is delayed by `CIV_REARM` unless within 15 tiles; 10 s / 15 tiles / 20 tiles / 1,200 / 1,800 / 3,600 are judgements; WATER_PREDATOR (class A) still wakes the player for the far beasts.
