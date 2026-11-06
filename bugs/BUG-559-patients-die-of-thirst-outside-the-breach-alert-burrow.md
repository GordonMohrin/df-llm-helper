# BUG-559 patients on Kern+ outside the BREACH alert burrow Tiefe+ die of thirst beside 47 caregivers; PATIENTS_OUT was a plain event
Status: fixed (offline, live-untested)
Severity: critical (loses citizens)
Found: 2026-11-06, Round 35 care/mood/trade (fix35-care), from the Run 16 FR-BUGS files and the runtime logs (read only)
Module: lua/dfllm/water.lua (care_step, care_check, patients_out)

## Actual
Run 16b i2 Brotherarrow y402 win d53-d83 (`E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/` events.jsonl #7224 PATIENTS_OUT, #7358 DEATH_CLUSTER,
kern.log 4906-5172; `runs/run-16b/FR-BUGS.md` "3 Patienten (26541, 26441, 26238) verdursten im NEUEN Hospital"). The cave dragon BREACH put the civ alert on
Tiefe+. The new hospital (94,103,133, beds at 100,103-106,133) lay on Kern+ (`hosp_out` 0) outside Tiefe+: "BREACH: 3 of 3 patients lie outside the alert
burrow Tiefe+ ... care: no Pflege+: BREACH: nobody is drawn out toward a seal that may be down". 47 caregivers (24 idle) stood confined in Tiefe+, the GiveWater jobs
ran for 15-36 days with `noeffect`, thirst 58,000-60,000 at the start, all three died (75,000).

## Root cause
`water.care_step` closed the care burrow Pflege+ in every BREACH ("never in BREACH", BUG-330 review fix) and `care_check` closed an open one on the mode change to
BREACH, so the caregivers the alert holds in Tiefe+ could never leave for patients on Kern+. The one remaining signal, PATIENTS_OUT, is an event (class A, once per
fight), not a question: nothing asked the player for a rescue.

## Fix
`care_breach` (config `water.care_breach`, default true) and `care_breach_near` (30): in BREACH the care burrow opens like in a SIEGE (tiles on Kern+ only: the patient,
the nearest accepted water, a free bucket) but only while no visible hostile is within `care_breach_near` tiles of any painted tile (fresh, complete census as before). A
SIEGE -> BREACH change keeps an open burrow and re-checks it at the BREACH distance (`care_check`); other mode changes still close it. A patient over `care_thirst` that
the care burrow does not reach (outside Kern+ in a fight, a hostile near, no accepted water, `care_breach` off) is a DECISION_NEEDED `patient_out` (A, urgent in
`wake.URGENT_DECISIONS`) with the reason the burrow is closed and `inspect hospital / water_sources / unit` commands, once per fight with PATIENTS_OUT.

## Tests
tests/lua/test_bug559_care_breach.lua (3), tests/lua/test_bug330_care_burrow.lua (the BREACH test now covers `care_breach` off), tests/test_bug559_563_care.py
(urgent decision, config keys).

## Live check
See CHANGELOG "Round 35 (care)".
