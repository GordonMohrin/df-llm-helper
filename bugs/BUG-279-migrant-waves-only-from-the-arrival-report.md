# BUG-279 brief 'migrants in 365 d: 0 waves' while the fort grew from 7 to 21: waves counted only from the arrival report
Status: fixed (offline, live-untested; why the reports were missed is open)
Severity: low (a wrong population diagnosis in brief and plan propose)
Found: 2026-10-29, Run 15 Earthboat (y374), fix6-alarm-noise
Module: `lua/dfllm/care.lua` (`pop_stress`, `M.census_waves`, `M.wave_add`, `EV:MIGRANTS`)

## Actual
`runs/run-15b-earthboat/FR-BUGS.md`: brief y374 summer d22 'pop trend: 21 of peak 21 ... migrants in 365 d: 0 waves, 0 people (last
673 d ago)'; population y372 spring 7, summer 13, y373 summer 15, y374 21, no births; one MIGRANTS event (n=6) for three or more waves.

## Cause
care counted a wave only from economy's MIGRANTS, which needs DF's MIGRANT_ARRIVAL report (economy.lua, read only here); a missed
report was never counted. Why the reports were missed is not verified offline.

## Fix
`M.census_waves` (each care population pass): a citizen id the census did not hold before (`p.known`, persisted) and not a baby is an
arrival; arrivals within `WAVE_GAP` (a game day) of each other are one wave (`p.wpend`), closed once a day passes without one. A wave
and a MIGRANTS within `WAVE_SAME` (3 days) are one wave, the bigger n counts (`M.wave_add`, also for MIGRANTS). The first pass after a
load without `p.known` only learns the ids (no wave for the fort so far).

## Tests
`tests/lua/test_care_pop_waves.lua` x2 (fail on 2b9c009).

## Live check
After the next migrant wave: `dfllm brief` 'migrants in 365 d: N waves, M people (last D d ago)' counts it with or without a MIGRANTS
event (`dfllm events --type MIGRANTS`); M equals the census growth minus births. If MIGRANTS stays missing, read the announcement
log for the wave's arrival text (read only).
