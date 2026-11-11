# BUG-744 patient_thirst DECISION at every thirst cycle of a served patient
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y432-y436 (418 `patient_thirst` events in the log, 9-11 patients 'thirst ~25,000-30,000', 31-34 carers, 27-31 free buckets, GiveWater jobs running), Run 16a i1 Basementflew (patient 26925 thirst 700 - 30,200 - 700, 50 decisions)
Module: `lua/dfllm/water.lua` (`M.DEFAULTS` alarm_*, `M.alarm_ripe`, the alarm block of `finish`), `dfpilot/fairplay.py` (`WATER_LIM`)

## Actual
i2 `events.jsonl`: DECISION_NEEDED `patient_thirst` for ONE patient at a time (units 29895 at 31820, 29332 at 31346, 29633 at 30370; ticks 178998749 / 179017947 / 179046898), each 'N GiveWater jobs running; jobs 0 open/2 running, 3-8 idle, 34 reach; buckets 28-31 free of 41; carers 34 of 8 wanted', key `run`, stuck 0, the same four commands. kern.log in between: 'water: 12-13 patients (max thirst 24563 / 29708), hospital ok, 2 wet sources, buckets 28-32 free, 0-4 GiveWater'.

## Why the patients are thirsty (looked at, not only silenced)
It is DF's own rhythm: a patient is handed water at about thirst 25,000-30,000 (the point at which a healthy dwarf drinks), so every served patient climbs to the alarm line once per cycle and falls back after the drink. The log shows different units crossing one after the other, each served within hours; the water zone 34 tiles away (under `patient_far` 40) costs a carrier a few hundred ticks against a 30,000-tick cycle; carers 34 of 8 wanted, 3-8 idle, 28 free buckets, 0 stuck jobs: no capacity shortage. The only real failures are the verdicts the kernel already reads (`noeffect`, `nowater`, `open`, `alert`, `stuck`, BUG-434 distance over 40, BUG-708 siege water), and they stay news at once. The 418 / 50 decisions came from `finish` (water.lua): `p.alarm[sid]` held a patient only while he was over 30,000, so every climb was a new 'fresh' crossing and woke the player at once, and the weekly reminder came with the verdict `run` (nothing a decision could change).

## Fix
- `M.alarm_ripe(c, age, thirst, gv, nohosp)`: a crossing is news when he has been over the line `alarm_grace` (2 game days) (not served), has reached `thirst_alarm + alarm_margin` (5,000: past DF's service point), or the verdict says nobody gives water (any verdict but `run`; a fort without a hospital zone gives no GiveWater job by design, so `nojob` is no news there).
- A patient leaves the episode only when his thirst fell `alarm_clear` (5,000) under the line, not at a dip under 30,000. `p.ann[sid] = {t, k}` remembers the last line that named him and the verdict: the same patient with the same verdict is announced again only after `alarm_repeat` (28 days); a new patient, a changed verdict or the weekly reminder (only while a ripe patient stands) still wake. `HOSPITAL_REMOVED` still wakes at once.
- `fairplay.WATER_LIM` knows the four keys (config validation).

## Tests
tests/lua/test_bug743_744_refit_climb_thirst_cycle.lua (`alarm_ripe` by age, margin and verdict), tests/lua/test_water.lua ('one patient_thirst line for all patients': the same patient and verdict again within `alarm_repeat` does not wake, after it does). No alert, lockdown, bridge or drill behaviour changed (a wake cadence); the `alert` verdict stays ripe at once.

## Open
DF's thirst rhythm is read from logs, not measured live; a patient who stays over the line for 2 days under `run` (a slow carrier) is announced once with the `run` verdict and then weekly. The 2 days / 5,000 / 28 days are judgements. No world-level test drives the `run` verdict with a job list. A Kernel reload is needed.
