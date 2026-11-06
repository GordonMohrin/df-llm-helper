# BUG-507 A GiveWater job hangs on a worker for 26 days, the patient dies of thirst, the player has no command
Status: fixed (offline, live-untested); open: a stalled child outside any detail with no pond zone beside him is only reported until the third round
Severity: critical (patients die in their beds)
Found: 2026-11-05, Run 16b i2 Brotherarrow y386 spr d23-d50: patient 26371 (bed 100,121,137) thirst 30,133 -> 61,495 -> dead
Module: `lua/dfllm/water.lua` (`M.stall_scan`, `M.stalls`, `unstick`, `stall_hospital`, verb `water.unstick`), `dfpilot/wake.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
Hospital ok, 15 carers, 14 free buckets, the pond zone 9 tiles off, DECISION patient_thirst x3, kern.log `stale GiveWater job ... its carrier(s) 20956,26505,26366 are no member of Orderlies: nothing to release`. The job hung on a CHILD (26505, "Dwarven Child", job GiveWater) who stood 26 days at 81,118,134 beside the dry Kern+ well 82,119,134 (wells wet 0). No dfpilot command could end the job (`jobs.release` is for constructions), PATIENT_DYING offered only inspect commands.

## Cause
BUG-383 acts only on the verdict `noeffect` and only on carriers who are members of the Orderlies detail (`water.lua` `M.restale`); a carrier outside it (the game picked a child) is "nothing to release". Nothing watched the job's worker and no decision carried an executable lever.

## Fix
- `M.stall_scan` follows every GiveWater / GiveFood / FillPond job by id with its worker and his tile (`p.sj`, at most 60). A worker who has not moved for `stall_days` (3) under the same job is stalled; it is a case when he is over `stall_need` (25,000 thirst) or DF's hungry line, or (Give jobs) a patient is over `thirst_alarm`.
- `M.stalls` (each water run, at most `stall_max` workers, a round per worker every `stall_every`): (1) the worker leaves Orderlies for a run (BUG-383's release, `p.rs` puts him back), (2) a Pond zone within `pond_near`+1 of him is removed (BUG-508), (3) from the third round (`stall_hosp`) the hospital zone a patient over `stall_dying` (45,000) lies in is removed (the zones screen, BUG-034's recipe; HOSPITAL_REMOVED with `stalled`).
- DECISION_NEEDED `job_stalled` (A, urgent wake) names the workers (child, job, days, tile, thirst, what was done) with `cmds`: `dfllm cmd water.unstick unit=<id>`, `inspect what=unit`.
- Verb `water.unstick {unit?}` (any mode): the ladder at once for one worker or all stalled ones, whatever need, cadence and cap.
- No job is removed (DESIGN 5.9; a removed job crashed DF in Run 9): only labor, pond and hospital zones, as the screens do.

## Tests
`tests/lua/test_bug507_509_water.lua` (a child's stalled GiveWater job -> job_stalled with the command and nothing removed at patient thirst 31,000; a walking worker is no stall; `stall = false`; Orderlies release and the third-round hospital zone; the verb in ALERT). `test_bug383_stale_give.lua` adapted (`stall = false`: it tests the noeffect release alone).

## Live check
The next hung job: kern.log `water: N water job(s) stalled ...`, the DECISION job_stalled, then `dfllm cmd water.unstick unit=<id>`. Whether DF drops the job after the worker left Orderlies or the zones went is NOT known (same assumption as BUG-383).
Open: a stalled child outside any detail beside no pond zone: only the patient's hospital zone rung (from the third round, patient over 45,000) acts; before that it is the DECISION and the verb.
