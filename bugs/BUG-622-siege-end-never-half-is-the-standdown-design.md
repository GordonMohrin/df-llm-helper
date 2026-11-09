# BUG-622 SIEGE_END `on station 0 (never half)` in every siege of a fort whose squads stand down unequipped
Status: fixed (offline, live-untested; wording only, the behaviour is the design)
Severity: low (a misleading end line sent three rounds of notes after a station bug)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y411-y433 (`soldiers 10 -> 10, on station 0 (never half); 10 stood down unequipped (no station order)`, eleven sieges)
Module: `lua/dfllm/siege.lua` (SIEGE_END), `lua/dfllm/military.lua` (`standdown`, `apply_squad`)

## Actual
Every SIEGE_END of the run ended `on station 0 (never half)`; since BUG-593 `; 10 stood down unequipped (no station order)` followed, the first half still read like a failure.

## Root cause
Not a station bug. `military.apply_squad` -> `standdown` (BUG-510): in a SIEGE / BREACH a squad of which fewer than `UNFIT_PCT` (30) percent hold a real weapon and wear body armor (Trumpetrealms: `armor 0-1/10`, 0 free melee weapons) gets no station order, its routine goes `off` and its order is cleared; unequipped soldiers are off duty and the civ alert keeps them in the refuge with the civilians (also for the deep defense against building destroyers: only fit squads go to the core station). The end line printed the `ep.ont < 0` default.

## Fix
`siege.lua`: with `ont < 0` and at least half of the soldiers stood down (`ep.sdmax`) the line says `on station 0 (by design: stood down, they stay in the refuge); 10 stood down unequipped (no station order)`; otherwise unchanged. No station order is issued in the refuge: an unequipped soldier gains nothing from a station, and a station order would pull him out of the civ alert's burrow.

## Tests
`tests/lua/test_siege.lua` (BUG-593 case extended; its kpi reading now starts at +0 so the episode never sees the default on_station 7).

## Open
Why the squads are unequipped (armor 0-1/10 beside 10 free body armors) is the kit cluster (BUG-598 / BUG-601), not this bug.
