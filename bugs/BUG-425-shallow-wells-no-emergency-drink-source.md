# BUG-425 1-2/7 wells are never a drink source, even when nothing else exists
Status: fixed (offline, live-untested); open: whether a 2/7 well really gives water in DF (Run 15d says it did not)
Severity: medium
Found: 2026-11-05, Run 16a i1 Manorsubtle y373 (`runs/run-16a/FR-BUGS.md`), main 03f4c1a
Module: `lua/dfllm/water.lua` (`emerg_wells`, `phase_sites`, `drink_access`, `drink_fix`, `served`), `dfpilot/fairplay.py`

## Actual
The fortcore stage 1 wells (17800, 17802, 17715) read 1-2/7 below them: "shallow < well_min 3/7", never accepted. A 1-tile pool (4/7) was accepted for a few weeks and
dried. With no brewable plant and no bank, nothing was a source; the player asked for 2/7 wells as an emergency threshold.

## Root cause
`water.lua phase_sites` accepts a built well only over water >= `well_min` (3/7, BUG-344 review: conservative, 1-2/7 wells gave a hospital no water). There was no
mode for "nothing else exists".

## Fix
- New config `water.well_emerg` (default 2, 0-7, 0 = off; `fairplay.WATER_LIM`, CONTRACTS): `M.emerg_wells` makes the built wells over water >= `well_emerg`/7
  accepted sources flagged `emerg` ONLY when no other source is accepted, the last scan is known and no non-cavern body has a bank the citizens reach. Not
  hospital water (`served` / the removal skip it), not in the state's `water.src` (so the plan keeps asking for real water), `drink_access.emerg` counts them
  apart and `ok` stays false (the BUG-401 decision keeps firing; its `auto` lists the emergency well), `drink_fix` starts `EMERGENCY: well N at x,y,z over only d/7 is
  accepted as a slow drink source (water.well_emerg ...)`, kern.log `water: EMERGENCY ...` once per well.
- Proof against it ends the mode for that well: a citizen over `well_thirst` (50,000) standing beside it (the Run 15d evidence) -> `emerg_no`, no source.
- The year-1 check (BUG-401) therefore triggers both actions at once: the decision and (BUG-424) the cistern request; the emergency well is the stop-gap meanwhile.

## Open
Run 15d (well 18324 over 1-2/7, 13 dead beside it) says such a well gave no water; the assignment says a 2/7 well gives slow water. The mode is on by default but
revoked by the first thirsty citizen beside it; `well_emerg 0` switches it off.

## Tests
`tests/lua/test_bug423_425_water.lua` (emerg_wells conditions incl. proof; in a run: log, drink_access, text, state src; well_emerg 0; the decision's `auto`).

## Live check
A fort with only 2/7 wells and no bank: kern.log `water: EMERGENCY: no other drink source, well N ...`, `inspect what=water_sources` / the `no_water` decision says
EMERGENCY; a thirsty citizen beside the well at 50,000+: the well loses the flag.
