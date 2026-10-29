# BUG-240 follow: the wake limit counts real hours only (silent for about a game year at timestream 500)
Status: fixed (offline, live-untested)
Severity: high (MOOD_RISK of the Fey mood that died, YEAR_REVIEW and SEAL_STUCK never reached the session)
Found: 2026-10-29, Run 15 Guildcleans (y374)
Module: `dfpilot/wake.py` (`WakeGate`, `Follower.poll`)

## Actual
The first `follow --max-s 580` printed 6 WAKE lines; the next three runs (about 10 real minutes each, nearly a game year)
printed nothing while `events --cls A` showed #419 MOOD_RISK, #488 YEAR_REVIEW, #546 SEAL_STUCK, #665/#672 MOOD_RISK (Fey
needs gems). `.follow.json` gate.pending held AUTO_FAIL c=15, DECISION_NEEDED c=2 and the rest. `WakeGate(per_hour=6)` counts
wall-clock seconds (3600 s, about 4 game years at timestream 500); URGENT bypassed it only for the siege types and the
interrupts, and nothing said that wakes were held.

## Fix
`URGENT_GAME` = YEAR_REVIEW, MOOD_RISK, MOOD_CRITICAL, DEATH, STRANDED, PATIENT_DYING, and DECISION_NEEDED with d.id
drink_low, food_low, thirst or patient_thirst (`urgent_game(e)`). The gate records the game tick at which such a type first
waited (`t0`, also for a burst saved by an older follow); `flush(now, tick)` lets the burst wake past the hourly limit and the
type cooldown once that type has waited `URGENT_GAME_TICKS` (one game day), merged as before and at most once per type per
URGENT_REPEAT_S. Follow passes the current game tick (state/heartbeat, read only when a limit holds). While the hourly limit
holds a burst, follow prints at most every `HELD_NOTE_S` (10 min) one line `HELD <date> | N events held by the wake limit
(6/h): TYPE xN, ... | next wake in ~M min; now: dfllm events --cls A --since N` (also in cli.log as `held`). Ordinary types
keep the 6 per real hour of RULES.md (the token budget). Not built: a separate budget of N wakes per game season.

## Tests
`tests/test_cli_wake.py::test_bug240_*` (MOOD_RISK held half a day, woken after one; YEAR_REVIEW and drink_low pass, D-07 and
SEAL_STUCK wait; an old saved burst; the HELD line once per 10 min with counts and types; a follower wakes a day-old MOOD_RISK
beside six wakes in the hour). All fail on 6dc0f19.

## Live check
At timestream with more than 6 class-A events per real hour: a MOOD_RISK/YEAR_REVIEW wake comes within a few seconds of game
time after the merge window although 6 wakes went out in the hour; ordinary types show as `HELD ... next wake in ~M min` at
most every 10 min; cli.log `held` lines match. `.follow.json` gate.pending of a held MOOD_RISK carries `ug` and `t0`.
