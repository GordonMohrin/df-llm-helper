# BUG-434 Patients die of thirst with 272 days of barrel drink: no water within reach, no hospital zone, no cistern asked
Status: fixed (offline, live-untested)
Severity: high (Run 16d i4 Mazelanterns y401: 11 died of thirst, 8 patients over thirst 60,000)
Found: 2026-11-05, `runs/run-16d/FR-BUGS.md` ("Verdursten trotz Trinkvorrat 272 d", "Patient verdurstet ohne Hospital"), main e0002e9
Module: `lua/dfllm/water.lua` (`give_diag`, the patient block of the water run), `dfpilot/plan.py` (`propose`, `request_facts`, `request_drafts`), `dfpilot/wake.py`

## Actual
Pop 81 -> 68 in y401. #10006/#10012: two citizens dehydrated at 75,000, DEATHS_PREVENTABLE; 8 patients at thirst 65,000; `hospital held back` (water 83-101 tiles away), PATIENT_DYING.
The fort held 272 days of barrel drink. The player asked for water carriers for patients without a hospital, or a cistern first.

## Root causes (evidence: E:/DF-test4/dfllm-runtime/r16d2-mazelanterns-site97/kern.log, water lines y399-y401)
1. GiveWater does not need a hospital zone: kern.log shows `hospital none ... 1 GiveWater` (jobs posted and taken) and `stale GiveWater job ... nearest water: none accepted`.
   It needs WATER (a wet well or a Water Source zone, see the BUG-324 comment in `water.lua give_diag`): barrels of drink are not water. The only accepted source was a zone 83-101 tiles
   away (outside the fort, where the carriers strand); placing a hospital zone fixes nothing, so none is placed.
2. Nothing asked for a cistern: the old request (`water.lua` gate, `hospital_water`) needs a hospital zone or a planned hospital project; economy's `no_water` request needs
   NO brewable plant and drink under `economy.drink.access_d`. Patients without a hospital and with plants in stock hit neither.
3. `plan propose` held the hospital back ("no site within 30 tiles of accepted water") but drafted no cistern: `_cistern_due` is false when `fort.hosp.fill.ok` is False (a
   bucket-fed cistern needs a brook it can be filled from), and the fallback `AQWELL` is a template that does not exist (`plan.py emergency_drafts`). The aquifer was known
   (aqshaft + cistern were appended by hand in y403).

## Fix
- `water.lua`: `water.patient_far` (40, 0 = off). A patient over `thirst_watch` with no accepted source (wet well / Water Source zone, not an emergency well) within `patient_far`
  tiles, or none at all, asks `PROJECT_REQUEST cistern why=patient_water` (`at` = the water tile nearest to the fort when a body without a bank is known, `n` its distance),
  at most every `request_every`, none while a cistern project is pending, whatever hospital zones exist; kern.log says "GiveWater needs water, not a zone".
  `give_diag` adds "nearest accepted water N tiles from him (> 40): ..." to the verdict (the verdict key, and so the BUG-383 stale-job release, is unchanged); `M.source_dist`.
- `plan.py`: `request_facts` accepts `patient_water` (with or without `at`, `CISTERN_WHY`); `request_drafts` drafts the piped cistern (BUG-424) when a safe route exists, else the plain cistern the fort can fill
  or the aquifer cistern. New `CISTERN_AQ` (`cistern p.water=aquifer`, the basin on a known aquifer level, template exists since BUG-262) and `_aq_cistern_due`: a held-back hospital
  and the emergency drafts take it when no brook can fill a bucket-fed one but an aquifer level is known (`fort.hosp.aq`, new in `hospital_facts`); `cistern_gate` does not warn about it.
- `wake.py`: follow answers `patient_water` with a tile like `no_water` (the piped cistern, safe plans only).
- Config: `water.patient_far` in `fairplay.WATER_LIM`.

## Tests
`tests/lua/test_bug434_435.lua` (4 BUG-434 cases: no source, near and far source, off, the distance in the cause), `tests/test_bug434_436.py` (held hospital + aquifer cistern, gate, emergency, request with and without a tile).

## Live check
A patient far from the water: kern.log `water: cistern: patient N ... no accepted water within 40 tiles`, the PROJECT_REQUEST in events, `cli.log auto:cistern_water` or the cistern in the next `plan propose` draft.
Open: whether an aquifer cistern fills in a fort whose aquifer is heavy (BUG-262's own live check). Not done: carrying water by hand to a lying patient is not a kernel action; a hospital zone does not change GiveWater.
