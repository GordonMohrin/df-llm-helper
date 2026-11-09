# BUG-593 SIEGE_END "on station 0 (never half)": every squad stood down and the line does not say so
Status: fixed (offline, live-untested)
Severity: medium (a wrong report that sent the players looking for station, burrow and crowd bugs)
Found: 2026-11-09, Run 16b i2 Brotherarrow y406 (`soldiers 11 -> 11, on station 0 (never half)`), Run 16d i4 Trumpetrealms y411-y418 (three times)
Module: `lua/dfllm/siege.lua` (`station_watch`, `status`, SIEGE_END), `lua/dfllm/military.lua` (`standdown`), `dfpilot/schema.py`

## Actual
`SIEGE_END ... soldiers 10 -> 10, on station 0 (never half)` with the squads "at the core station" in the SIEGE_DEEP text.

## Root cause (read from the three runs' kern.log and events)
Not a station problem. In all three sieges every squad stood down on purpose (BUG-510: fewer than 30 % of its soldiers hold a real weapon and wear body armor; kern.log `SIEGE: squad A stands down: 0 of 3 soldiers ... (missing: weapon 3, body armor 3; free: 2 melee weapons, 54 body armors ...)`, worn 0-25 %), so no squad had a station order and `on_station` stayed 0. `siege.station_watch` already took the stood-down soldiers out of the denominator, which left `sol` 0 and `ep.sol0` unset, so SIEGE_END fell back to the current soldier count (`11 -> 11`) and printed nothing about the stand-down. The other suspects were checked and are not the cause: the stations lay on the soldiers' walk group (`off_group` / BUG-215 moves a station, an `unreachable` move is rare, Trumpetrealms had one), the STATION_MOVED "kept" of BUG-543 only holds a station that a bridge raise waits for (no relocation onto the crowd), and soldiers with a station order ignore the civ alert burrow. The real cause is the empty kit, BUG-591.

## Fix
`ep.sdmax` = the most soldiers standing down in the episode (`military.kpi` `sd`); SIEGE_END carries `stood_down` and the line ends `; N stood down unequipped (no station order)`; SIEGE_STATUS carries `sd`. A squad that stands down gets its refit and weapon re-plan at once (BUG-591), so a siege that lasts days is no longer unequipped for `refit_days`.

## Tests
`tests/lua/test_siege.lua` (+1: SIEGE_STATUS `sd`, SIEGE_END `stood_down` and the text), `tests/lua/siege_world.lua` (the fake military's `kpi_x`)

## Live check
A siege with unequipped squads: `SIEGE_END ... on station N (never half); 11 stood down unequipped (no station order)`; with equipped squads the line is unchanged.
