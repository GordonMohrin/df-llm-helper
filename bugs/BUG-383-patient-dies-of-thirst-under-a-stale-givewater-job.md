# BUG-383 a patient dies of thirst under a GiveWater job that runs for weeks
Status: fixed (offline, live-untested); open: a patient no carrier can reach or serve
Severity: high
Found: 2026-11-04, Run 16b (i2 Ostgate y381 autumn, unit 26275, `runs/run-16b/FR-BUGS.md`), main ec9bd8e
Module: `lua/dfllm/water.lua`

## Actual
PATIENT_DYING / patient_thirst for 26275: thirst 31,055 -> 60,594 -> dead at 75,001 (events 2213, 2282, 2293), always `1 GiveWater
job running` (0 open, 56 carers, 38 idle, 17 free buckets, accepted water 3 tiles away); the patient lay unconscious with 3
wounds. After 25 game days the verdict turned `noeffect` (BUG-343) and nothing happened.

## Root cause
`give_effect` (water.lua) only reports. The job the game keeps for a patient can hang on its carrier for ever, and the kernel
has no job removal (DESIGN 5.9, lint: `removeJob` only in `act.cancel_own_lever_job`; a removed job crashed DF in Run 9).

## Fix
`M.restale` (after `give_effect`, called each water run): on the verdict `noeffect` it takes up to `restale_max` (2) carriers
of the running GiveWater jobs that are members of the Orderlies detail off that detail through `act.work_detail` for one run,
so the game drops the stale job and posts a new one; the next run puts them back (`p.rs`); again after `restale_every` (2 days);
a carrier who is no member (labor from elsewhere) is left alone, with a kern.log line. `job_scan` collects the workers
(`sc.w_workers`). The release note leads the PATIENT_DYING / patient_thirst reason (`stale job released: carrier N off
Orderlies (round R)`). Config `water.restale` / `restale_max` / `restale_every` (baseline.json, fairplay WATER_LIM).

## Open
Not decided offline: whether DF drops a running GiveWater job when its carrier loses the labor. A patient who is unconscious in a
bed far from water, or a hospital bed near water (a bed switch), has no act; the `noeffect` text stays the signal.

## Tests
tests/lua/test_bug383_stale_give.lua (2). Fails on ec9bd8e.

## Live check
A patient over thirst 30,000 with a running GiveWater job and rising thirst: 2 days later `water: stale GiveWater job (...):
carrier N taken off Orderlies for one run`, the next run `carrier(s) back in Orderlies`; the GiveWater job is a new one
(job id changes in `inspect`), thirst falls.
