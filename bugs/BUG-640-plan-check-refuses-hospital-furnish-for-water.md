# BUG-640 `plan check` refuses `hospital furnish=1` with 'no water site' although the hospital stands
Status: fixed (offline, live-untested)
Severity: medium (the table of a finished hospital is drafted by `plan propose` and rejected by `plan check`; the entry has to be struck by hand)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y437 (propose drafted `hospital furnish=1` for no_table, `plan check` ERROR 'no valid site ... its patients would die of thirst' with the hospital zone 17697 'hospital ok'; round 40 BUG-623 fixed the Occupancy clash only)
Module: `dfpilot/plan.py` (`hospital_gate`)

## Actual
ERROR in `plan check` for a plan whose only hospital build is the table.

## Root cause
`plan.py` `hospital_gate` (`adds`, about :1146): it took every `new_builds` entry with `tpl == hospital`, the furnish build included, and ran `hospital_water` on it, i.e. the check for the water of a NEW hospital's site (BUG-034). A furnish build has no site of its own: it puts a table into the room that stands (BUG-581 / BUG-623).

## Fix
`adds` leaves out builds with `p.furnish`. A new hospital in the same plan still gets the water check (and the 'seasons[N]' text).

## Tests
`tests/test_bug637_641_f41_proj.py::test_hospital_furnish_is_not_refused_for_water_but_a_new_hospital_still_is`

## Live check
`dfllm plan check y.json` for a draft with `hospital furnish=1` and a standing hospital: no ERROR from the hospital gate.
