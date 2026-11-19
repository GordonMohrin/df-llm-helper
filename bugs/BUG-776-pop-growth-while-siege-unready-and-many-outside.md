# BUG-776 population grew 39 -> 52 between two sieges while R0 stood UNREADY and a third of the fort worked outside Kern+
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16a i1 Basementflew y539-y544 (kern 87b10464; FR-BUGS 'BUG 2' wish 3): 'Pop-Wachstum ueber ~40 stoppen, solange R0 (refuge_dry/audit_fail) UNREADY ist'; at the 2nd surprise siege 35 of 52 citizens stood outside Kern+, 16 died in one day
Module: `lua/dfllm/readiness.lua` (`M.UNSAFE`, `UNSAFE_FLAGS`, `ceiling`, `hold_text`, state `ready.uh`)

## Actual
R0 (`refuge_dry`, `audit_fail`, the new `lever_outside`) holds the automatic drills but not the population: `M.CAPS[0]` is 100, so migrants kept coming (39 -> 52 between the sieges) into a fort whose refuge had no drink and whose bridge levers lay outside the walls; the dead of the second siege were the newcomers working outside.

## Root cause
Only `open_perimeter` (FR-70), `defense_short` (BUG-481 / BUG-742) and the plan / player / famine ceilings hold max-pop; R0 blockers that kill in a siege (no drink in the refuge, a failed audit, levers outside) held nothing.

## Fix
`readiness.lua`: in PEACE, while R0 fails on one of `UNSAFE_FLAGS` (`refuge_dry`, `audit_fail`, `lever_outside`) and at least `UNSAFE.outside` (10) citizens AND at least `UNSAFE.share` (25) % of the population stand outside Kern+ (`census.u.outside`, the same count the recall uses), a fort of `UNSAFE.hold_pop` (30) citizens or more keeps max-pop where it is: `st.uh` = the population at that moment (persisted; state `ready.uh`), `ceiling` takes it (why `unsafe`, `pop.hold` 'unsafe 50', the POPCAP event, `migrant_cap_note`). The hold stays while the flags stay (no flicker when the outside count moves with the day) and ends when they are gone. Outside PEACE it neither starts nor ends. A fort under 30 citizens keeps growing (a small fort cannot be 'unsafe' for growth).

## Open
The hold is a push to fix the blocker, not a fix: a fort that cannot make drink for the refuge or mechanisms for the lever stays at its size for as long as that lasts (the DECISIONs `refuge_dry` / `lever_outside` say what is missing). The thresholds are constants (`M.UNSAFE`), not config.

## Tests
`tests/lua/test_bug774_776_lever_home.lua`: refuge dry and 15 of 50 outside: max-pop held at 50 (R0 cap 55), stays 50 with 58 citizens, rises again once the refuge has drink and `ready.uh` is gone; 4 outside: no hold; refuge stocked: no hold; the `lever_outside` blocker holds too.

## Live check
kern.log 'readiness: max-pop held at N: R0 blocked (...) and M of N citizens stand outside Kern+', POPCAP 'max-pop N (unsafe)', status `pop.hold` 'unsafe N'.
