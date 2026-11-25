# BUG-869 inspect hospital never said what the patients wait for
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i2 Whirledrampart: 14 permanent patients with one closed wound each, 'labor: 29 of 29 starving postings are stale (oldest Diagnose Patient, 2507222 ticks)' beside doctors with the labor on; why the doctors never take DiagnosePatient is NOT shown by any live data.
Module: `lua/dfllm/water.lua` (`M.treat_waits`, `M.treat_text`, `M.inspect_hospital`)

## Root cause
Reporting gap only: `inspect what=hospital` listed gaps but not the treatment postings, their workers or what the doctors do.

## Fix
`inspect what=hospital` appends `waits: DiagnosePatient N posted, M taken; ...; K doctors (DIAGNOSE on) now: job counts` and carries `data.waits` (types posted/taken, up to 12 patient ids of unclaimed postings, doctor jobs) and `data.waits_text`. Read only, no cure.

## Tests
`tests/lua/test_bug864_870_ruest.lua` (posted/taken per type, text), `tests/lua/test_water_m1.lua` (message unchanged without postings).

## Live-Erwartung
i2 (on the next player look): `inspect hospital` names which treatment postings stand unclaimed and what the doctors do now: the measurement for the next round. NOT promised: any cure for the patients.
