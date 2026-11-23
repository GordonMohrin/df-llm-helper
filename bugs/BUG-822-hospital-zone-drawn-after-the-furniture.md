# BUG-822 bp hospital drew its zone after the furniture: one unbuildable piece meant no hospital zone at all
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-23, Run 16a i1 Basementflew y423-y558 (no hospital for 135 years; every `bp.place hospital` ended build_lost, "missing b x4", traction bench, chests); NEU1 P9 (decision E8)
Module: `dfpilot/bp/rooms.py` (hospital template), `lua/dfllm/runner.lua` (`Q.OPTIONAL`, `Q.OPT_TYPE`), `lua/dfllm/care.lua` (`M.HM`, config `care.hosp_min`)

## Actual
The hospital template asked for 4 beds, a traction bench, a table, chests and a well, and its `m location=hospital` zone stage came after the build stage. A single missing piece ended the project build_lost before the zone existed, while beds stood elsewhere in the fort.

## Fix
(a) bp: defaults `beds=1`, `bench=0`; the zone stage right after the dig (surface: before the build); table, traction bench, chests and well are optional in the runner and never block. (b) Kernel: `care.M.HM.phase` draws a 1x1 hospital zone (act `hospital_zone`) over the free built bed nearest accepted water (within `water.near`, on the walk group, no owned bedroom), once a day while no hospital zone holds a bed; the preconditions stand in state `care.hosp` and HOSPITAL_MIN (B).

## Open
A 1x1 zone holds no table or traction bench (the bp template adds them); no bed is built by the kernel.

## Tests
`tests/lua/test_neu1_pflege.lua` (hosp_min, 3), `tests/test_bug384_surface_hospital.py`, `tests/test_bug581_585_f37_econ.py`, goldens `tests/bp/golden/hospital.*`. Design: `docs/v2/NEU1-pflege.md`.
