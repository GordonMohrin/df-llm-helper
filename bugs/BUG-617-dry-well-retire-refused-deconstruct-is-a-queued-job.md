# BUG-617 well.retire of a dry well answers 'deconstruct refused': the deconstruction is a queued job, and dry_well offers commands that fail
Status: fixed (offline, live-untested)
Severity: high (the offered fix of the dry_well decision never worked; the decision came back for 10 years)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y418-y428 (`well.retire id=17824` -> `ERR deconstruct refused`, act.well_remove ACT_FAIL, the same `dry_well` decision at patient thirst 27,045 ... 47,150), Run 16a i1 Basementflew (GiveWater carrier at the DRY well 18674, 96,72,129)
Module: `lua/dfllm/act.lua` (`I.well_remove`), `lua/dfllm/water.lua` (`well.retire`, `stalls`, `M.cistern_room`)

## Actual
`well.retire` -> `water.lua` -> `act.well_remove(id)` -> `dfhack.buildings.deconstruct(w)` returned false and the act said 'deconstruct refused'. The carriers went on standing at the dry well; each `dry_well` decision offered the same command. A cistern room's well was offered without `approve:true`, which the verb refuses.

## Root cause
- `lua/dfllm/act.lua I.well_remove` (the deconstruct line, act.lua:1294 before the change): DFHack's `buildings.deconstruct` "Returns true if the building was destroyed and deallocated immediately" (Lua API); for a BUILT building (a well) it queues a Remove Building job and returns false, so the act always called a working removal 'refused'. `pond_remove` / `hospital_remove` work on zones, which go at once.
- `water.lua stalls`: the decision did not know a removal was pending (nothing read `markedForRemoval`), and offered `well.retire` for cistern-room wells without `approve=true`.

## Fix
- `well_remove`: deconstruct false + `dfhack.buildings.markedForRemoval(w)` is `ok, 'queued'`; unmarked stays 'deconstruct refused'. The verb says `removal of the dry well N at x,y,z (building screen remove): ...; a Remove Building job is queued, a builder takes it` and returns `queued 1`; a well already marked answers ok `already marked for removal` and sends nothing.
- Source rows carry `removing` (`markedForRemoval`); carriers at such a well get no new `dry_well` / `job_stalled` decision (log line only), the ladder goes on; `pond_block` skips it.
- `dry_well` commands: `well.retire id=N`, with ` approve=true` for a well inside a cistern room (`M.cistern_room`).

## Tests
`tests/lua/test_kern_act.lua` (well_remove queued / refused), `tests/lua/test_bug615_617_water_deaths.lua` (verb message, already marked, approve=true in the decision, no decision for a marked well)

## Live check
`dfllm cmd well.retire id=<dry well>`: `ok removal of the dry well ... a Remove Building job is queued`; a builder removes it, then the carriers fill at the accepted water. If no builder takes the job it stays marked (the sources row `removing`). Which well the carriers choose is DF's: only the well's removal stops them. `markedForRemoval` / the queued-job reading of `deconstruct` come from the DFHack Lua API text, not from a live read.
