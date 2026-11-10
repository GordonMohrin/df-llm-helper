# BUG-650 Ceiling held for a refuge no build can fix
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16a i1 Basementflew y455-y458: ceiling held 'defence short (refuge_dry)' for years; `refuge_drink` needs a refuge room of the manifest, made only by fortcore stage 3, impossible under the aquifer
Module: `dfpilot/plan.py` (`refuge_unbuilt`, `defense_gaps`, `defense_on`, `defense_cap`, `refuge_free_note`)

## Actual
`pop_ceiling` sat on the citizens (no migrant wave) while the only fix (a refuge drink store) had no site.

## Root cause
BUG-377 counted `refuge_dry` as a hole that holds growth. The fix is a `refuge_drink` store (FR-69), whose ranking needs the refuge room of the manifest; with none and no stage 3 under way `drink_fit` is 0 and the gap can never close. (The kernel's own ceiling holds, readiness `defense_short`, count traps and armor only, not refuge_dry.)

## Fix
`refuge_unbuilt(s, fort)`: `refuge_dry` with `fort.refuge.drink_fit == 0`, no store standing or under way and no stage 3 under way is a gap no build closes: `defense_gaps/defense_on/defense_cap` (new `fort` argument) leave it out, and the draft's notes say `BUG-650: refuge_dry holds no ceiling: ...`. Every other gap holds as before; a store, a room or a stage 3 under way keeps `refuge_dry` a gap.

## Tests
`tests/test_bug645_650_f41_misc.py` (1)

## Live check
Basementflew: `plan propose` with `refuge.drink_fit 0` sets the ceiling by the policy (and the other gaps), the notes carry the BUG-650 sentence; with a refuge room the ceiling is held as before. Not done: a surface refuge stock (no template).
