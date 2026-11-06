# BUG-508 Dwarves dehydrate and starve in FillPond / GiveWater jobs at a dry well beside 846 days of drink
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-05, Run 16b i2 Brotherarrow y386 spr d52-d70: DECISION thirst_unit #3382: captain 24335 thirst 53,360, hunger 65,410, job FillPond at 81,119,134 (dry Kern+ well 82,119,134), 33 wounds, stress 91,500
Module: `lua/dfllm/water.lua` (`M.stalls`, `unstick`)

## Actual
The reach check was green (21 citizens on one walk group, drink / food 100 % in the main group), so the units were not cut off: they stayed in water jobs that never end (the well was dry: `wells wet 0`). `pond_loops` removes a Pond zone only beside a WET well; a Pond zone beside a dry one fills nothing and a FillPond worker waits there. thirst_unit named the job and nothing else.

## Fix
Same machinery as BUG-507 (one stall tracker for GiveWater, GiveFood and FillPond): a FillPond worker over `stall_need` thirst (or DF's hungry line) who has not moved for `stall_days` loses the Pond zone within `pond_near`+1 tiles of him (`act.pond_remove`, the zones screen's remove: DF cancels the jobs of a deleted zone); a healthy worker in a long job is not touched. The DECISION job_stalled names him (`FillPond`, days, tile, thirst, `pond zone N removed`); `water.unstick unit=<id>` repeats it on request.
Not done: the dry well itself (a cistern or piped well is the planner's, BUG-263/264/448).

## Tests
`tests/lua/test_bug507_509_water.lua` (BUG-508: pond zone 77 removed for the worker at thirst 53,360, left alone at 1,000).

## Live check
A FillPond worker at a dry well: kern.log `water: ... stalled ...`, `pond zone N removed`, the unit's job changes within a day.
