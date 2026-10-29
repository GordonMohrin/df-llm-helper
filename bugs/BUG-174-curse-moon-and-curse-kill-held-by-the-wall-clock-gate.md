# BUG-174 CURSE_MOON and the curse_kill question are held by the 600 s wall-clock gate at timestream speed
Status: fixed (offline, live-untested)
Severity: high (moons 2, 3, 5 and d155 without CURSE_MOON; no curse_kill for the d77, d155 and d181 waves)
Found: 2026-10-29, live test round 2 i2 (M4-CURSE_MOON, M4-KILLQ, NEW2; skeptic: moons pass only when 600 real s passed since the last mark)
Module: `lua/dfllm/curse.lua` (`moon_event`, `kill_question`)

## Actual
Both used `util/cadence.due` with `wall_s = wake_wall_s` (600). At 300-500 ticks/s a lunar month is 60-100 real seconds, so news (a new moon day
token, a grown set of were-forms) waited for 10 real minutes and was lost.

## Fix
`wall_s = 0` for both: the moon day token (one per moon) and the set of were-form ids are the news; the tick gate `4 x curse_every` stays.

## Tests
`tests/lua/test_curse_live2.lua` BUG-174: two moons and two were-form sets within 600 wall seconds give two CURSE_MOON and two curse_kill
(fails on b805745).

## Live check
At timestream speed with cursed units: `dfllm events --type CURSE_MOON` has one event about 4 days before every full moon; every wave that
adds a were-form gives a `DECISION_NEEDED curse_kill` naming the whole set.
