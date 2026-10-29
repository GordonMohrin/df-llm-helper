# BUG-173 `inspect what=unit` does not find a nicknamed unit by his real name, lists empty ANYTHING emotions, shows blood_pct -1 for the dead
Status: fixed (offline, live-untested)
Severity: medium (the player's sheet reader answers 'no such citizen' or a wrong thought list)
Found: 2026-10-29, live test round 2 i2 (M4-INSPECT-UNIT, NEW6; skeptic: nickname 'Testnick' on 42129 -> 'Lorbam Ekastreg' no such citizen;
emotion slots 199-206 type ANYTHING, thought -1, strength 0)
Module: `lua/dfllm/curse.lua` (`find_unit`, `index`, `thoughts_of`, `inspect_unit`)

## Actual
- With a nickname DF's readable name is "`Blinky' Savotdumat": the nickname stands in place of the first name, and the nickname strip leaves only
  the last name, so the real first name was never compared (inspect and the report index both).
- The emotions vector holds empty slots (ANYTHING, thought -1, strength 0) and is not in time order; every list began with 'ANYTHING'.
- A dead unit read `blood_pct -1`.

## Fix
- `unit_keys(u, env)`: the sheet name without the nickname and the real `u.name.first_name` + the last name (`translateName(name, false, true)`);
  `find_unit` and the name index match either (first name alone as before).
- `thoughts_of`: skips type ANYTHING and entries without thought and strength 0; sorts by (year, year_tick) newest first.
- `blood_pct` only for a living unit with `blood_max > 0` and `blood_count >= 0`.

## Tests
`tests/lua/test_curse_live2.lua` BUG-173 (two tests; fail on b805745).

## Live check
Give a citizen a nickname in the game; `dfllm cmd inspect '{"what":"unit","key":"<first> <last>"}'` finds him; `thoughts` has no 'ANYTHING'
and starts with the newest thought; a dead unit has no `blood_pct`.
