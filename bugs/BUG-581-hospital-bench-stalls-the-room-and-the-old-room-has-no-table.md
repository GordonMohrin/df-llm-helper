# BUG-581 Hospital project stuck at 28 % on its traction bench; a hospital room of an older template has no table
Status: fixed (offline, live-untested)
Severity: high (patients died of thirst beside a room that never finished; `no_table` for years)
Found: 2026-11-09, Run 16a i1 Basementflew y423-y426 (`build_lost at build` 28 %, 8 retries, 300 days), Run 16d i4 Trumpetrealms y411-y415 (`hospital ok`, 4 beds, gaps no_table / no_diag / no_bone / no_suture / no_dress / no_plaster / no_soap)
Module: `lua/dfllm/runner.lua` (`Q.OPTIONAL`, `Q.optional_missing`, `measure_build`), `dfpilot/bp/rooms.py` (`hospital` p.bench / p.furnish), `dfpilot/bp/sites.py` (`_furnish_hospital`), `dfpilot/plan.py` (`hospital_table`)

## Actual
The hospital's build stage counted the traction bench (cell `R`) as a lost piece: it needs a mechanism, the fort had no reachable hard stone, quickfort refused the tile or DF never built it, `lost` stayed over `lost_pct` and the project parked as `build_lost` for 300 days. In the other fort the room stood with beds but no table and no command put one there.

## Root cause
`runner.lua` `measure_build`: every unbuilt building of the stage was `pend` and every refused cell a loss, with no notion of an optional piece. `rooms.hospital` always placed the bench; nothing drafted a table into a standing hospital room.

## Fix
`runner.Q.OPTIONAL = {hospital = {R = true}}`: a bench not built is `done` for the stage (logged `optional piece(s) not built`), a bench cell nobody could place is no loss (`Q.optional_missing`); any other missing piece still ends `build_lost`. `hospital` p.bench = 0 leaves the bench out and p.furnish = 1 is ONE table on a free wall-side floor tile of a hospital room of the manifest (`sites._furnish_hospital`, no dig, no zone). `plan.hospital_table` (run in `plan propose`): audit gap `no_table` + a hospital room drafts `hospital furnish=1` once (max 2 per fort), a NEW hospital build gets bench=0 while `fort.nostone`, the gaps the plan cannot build (a doctor's labor, plaster, soap) are reported in the notes.

## Tests
`tests/lua/test_bug581_hospital_bench.lua` (4: refused bench, unbuilt bench, another piece still lost, bedrooms unchanged), `tests/test_bug581_585_f37_econ.py` (bench=0 emit, furnish rank/emit/refusals, `hospital_table` draft and notes, bench=0 without stone)

## Live check
`plan propose` in a hospital-without-table fort: `hospital furnish=1`; a fort with no hard stone: the hospital build is done after its beds, kern.log `optional piece(s) not built`.
