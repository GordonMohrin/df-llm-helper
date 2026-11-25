# BUG-877 13 of 37 i1 deaths were 'unknown' with no position, thirst, job or hazard
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank: DEATH 'not found yet, missing in the unit list' for 26422, 26659, 19948, 26882, 26660, 28762, 26423, 28619, 29260, 24165, 26277, 29619, 29261; the player's `inspect unit` still read the position (180,10,143).

## Root cause
`lua/dfllm/deaths.lua` `D.classify` returned in the 'not found yet' branch BEFORE `timers`, `pos_of`, `last_job` ran.

## Fix
The branch now reads thirst/hunger/position/job from the unit object (cause stays unknown, found false); `care.M.vanished` adds seal's last away record (`seal.away_of`: position, job, since), `out` 1 when the census had him outside, and `haz` (`sense.water_at` at the position: `water 5/7`, `beside water 2/7`) to the DEATH event (contract `out`, `haz`).

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-877: classify of a unit missing from the list carries pos and thirst).

## Live-Erwartung
A DEATH with `found 0` carries `pos`, `thirst`, `hunger` when the unit object answers, and `out`, `haz` when known (PROMISED). The job at the moment of death stays unknown (a dead unit has none; only the last away record's job).
