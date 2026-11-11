# BUG-756 four doctors for 10-16 patients: DiagnosePatient waits unclaimed, a doctor at extreme stress stays a doctor
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y435 (`inspect workload`: DiagnosePatient 11 unclaimed, no_surgery / no_suture gaps; kern.log "doctors: 4 of 4")
Module: `lua/dfllm/care.lua` (`phase_doctors_run`, `M.doctors_want`, `may_doctor`)

## Actual
`care.doctors` (baseline 4) fixed the number of citizens with DIAGNOSE, SURGERY and BONE_SETTING at four however many patients lay in the hospital; 11 diagnoses waited.

## Root cause
`phase_doctors_run` used `c.doctors` as the target and `may_doctor` knew no stress rule.

## Fix
`M.doctors_want(base, patients)`: one doctor per `DOC_PATIENTS` (3) patients, at most `DOC_MAX` (8), never fewer than the baseline; the patients are the citizens with `needs_healthcare`. `may_doctor` refuses a citizen of the extreme-stress set. A raise is logged once a week.

## Open
Doctors are made from free adults without a squad, mood or patient state; a fort with no free adult stays at what it has (the "only N of M and no free adult to train" warning as before). The audit's `no_surgery` / `no_suture` need a skilled doctor, not only a labor.

## Tests
`tests/lua/test_bug756_doctors.lua`: the want (4, 4, 5, 6, 8, 0), 15 patients make a fifth doctor, no patients no extra one, stressed citizens are skipped.

## Live check
kern.log "doctors: N patients, M doctors wanted" with more than 6 patients; DiagnosePatient jobs get claimed.
