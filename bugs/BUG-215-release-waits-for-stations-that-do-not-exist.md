# BUG-215 siege_release and breach_stuck wait for soldiers at stations that do not exist
Status: fixed (offline, live-untested)
Severity: high (wrong decision: a far harmless invader holds the BREACH without end; only the player can end it)
Found: 2026-10-29, live test round 4 (E:/DF-test4, Trussroads), the tester's BUG-171 check, confirmed by the skeptic
Module: lua/dfllm/stations.lua (new `S.stationed`), lua/dfllm/military.lua (kpi `off.unreach`, `in_kern`), lua/dfllm/reflex.lua
(`soldiers_on_station`, the release log line), lua/dfllm/siege.lua (`breach_stuck`)

## Actual
A wild gorlak 43136 about 70 tiles out held the BREACH from tick 295714691 to past 295737794 (23,000+ ticks against max_days 10 =
12,000): on_station 0 of 8, kpi off {nost: 8}. Only the DECISION_NEEDED kill_lone_intruder ask came; no release, no bridge_stuck.

## Cause
reflex's release and siege's breach_stuck both demanded `on_station * 2 >= soldiers`. With no station order (BUG-214) or an unreachable
one nobody can stand on a station, so the condition never became true.

## Fix
`dfllm.stations.stationed(kpi)` (pure, used by both): true when half of the soldiers with a reachable station stand on it, or when none of
the rest has one (kpi `off.nost` + the new `off.unreach`: the squad's station lies on another walk group than its soldiers) and half of
all soldiers stand in Kern+ (new kpi `in_kern`; no march out). The release log line says 'with the soldiers placed: no station order for
8 of 8, 8 in Kern+' instead of 'at their stations'. Standing outside Kern+ without a station keeps both waits.

## Tests
`tests/lua/test_stations.lua` BUG-215 (stationed rules, kpi nost/in_kern on the world), `tests/lua/test_m3_lone.lua` BUG-215 (release
at max_days, none outside Kern+), `tests/lua/test_m3_breach.lua` BUG-215 (bridge_stuck fallback); each fails on 5e9e719.

## Live check
A lone harmless invader far out in BREACH while the squads have no station order: after confine.max_days kern.log 'lone harmless
intruder N cleared after X days in BREACH with the soldiers placed: no station order ...' and LOCKDOWN_END limit.
