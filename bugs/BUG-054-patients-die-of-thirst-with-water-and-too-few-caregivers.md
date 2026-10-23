# BUG-054 Patients die of thirst in a served hospital: 4 caregivers for 5 patients counted as "present", nothing raised them, nothing escalated
Status: fixed (see Fix commits at the end; offline, live-untested): caregivers scale with the patients through the
Orderlies work detail, patient_thirst names the shortfall, PATIENT_DYING (A) at thirst 60,000 with the caregivers' state;
why the game's own GiveWater jobs did not keep up is NOT decided offline (live data below)
Severity: critical (loses citizens: 5 patients dead of thirst at once, the run went from 49 citizens to 1)
Found: 2026-10-22 and 2026-10-23, Run 11 fort (y497 summer-autumn, after siege 14), from the game session's notes 18, 24
(bugs/RUN11-offene-bugs-und-FR.md); main f17e2b3
Module: `lua/dfllm/water.lua` (`phase_units`, `finish`, new `M.carers`), `lua/dfllm/act.lua` (`A.TOOL_DETAILS`),
`lua/dfllm/util/contract.lua`, `dfpilot/schema.py`

## Actual
- DECISION_NEEDED `patient_thirst` with the cause text "water, buckets and caregivers present": 3-5 patients at thirst
  30,000-40,293 (units 28970, 28642, 28483), 24-27 of 62 buckets free, 4 caregivers (29009, 29031, 29032, 29035).
- y497 d31: five patients (28970, 29039, 28627, 29100, 28968) dead of thirst at once (thirst 75,000, hunger 80-119k) in a
  fort that reported "hospital ok"; afterwards more deaths, the last state 1 citizen. The hospital was served (a wet well):
  BUG-034's removal acts on a DRY hospital only.

## Cause (proved from the code at f17e2b3)
1. **Nothing ever gave anybody the FEED_WATER_CIVILIANS labor.** `grep -rn FEED_WATER lua/` finds only reads:
   `water.lua:234-241` (`carer`: counts the citizens who have the labor) and economy's `keep_labors` /
   `labor.supply` lists. The number of caregivers was whatever the game's own default work detail held (the live
   `labormanager dump` of note 63 lists a detail `Orderlies`, `managed=0`: the kernel's economy is the sole writer of
   the memberships it keeps, and keeps none for the orderlies). 4 caregivers in a fort of 49 is that default.
2. **The cause text only knew "none".** `water.lua:1061` (old) added "no caregiver with FEED_WATER_CIVILIANS" for
   `#r.carers == 0` only; 4 caregivers for 5 patients (one over 40,000) read "caregivers present". The wake line ended
   with the generic recipe "check the GiveWater jobs: caregivers, buckets, the way to the water" (`water.lua:1065`).
3. **A wet hospital got no action at all.** The only act on thirsty patients was `remove_dry` (`water.lua:792-846`),
   which needs `not hosp_ok`; the line itself repeats weekly at best (`alarm_every` 7 days plus the 600 s wall wait,
   BUG-008). From 30,000 to 75,000 a thirst timer needs ~37 game days: five weekly lines, the same text each time.
4. **No higher tier.** Thirst 60,000 (death at ~75,000) was the same line as 30,000.

## Not decided offline (live data that decides)
Why the existing caregivers did not keep up: busy elsewhere, no GiveWater job posted, jobs open but unreachable, or too few
hands. Read-only, from the next live episode: `dfllm cmd inspect '{"what":"water_sources"}'` `carers` (have, want, idle,
give = citizens giving water, mine = added by the kernel, err), the PATIENT_DYING event (`idle`, `give`, `open`/`run` =
GiveWater/GiveFood jobs on the job list without/with a worker, `buckets`, `hosp`) and the kern.log line
`water: N patient(s) near death of thirst ... (GiveWater/GiveFood jobs: N open, N running)`. Open jobs while caregivers
stand idle means a path or priority problem (then more hands do not help: tell the player, `inspect reach`); no jobs at
all means the game posts none (the BUG-034 rule: a hospital without accepted water; here the well was wet); busy
caregivers means capacity (what this fix adds). Also open: the work detail's name and mode on a given save (`Orderlies`
is read from note 63; `labor_info.work_details[i].name`, `.flags.mode`, `.allowed_labors`): a save without that name makes
the add fail with `no work detail Orderlies` (named in the line, asked again after a week).

## Fix
- `water.M.carers` (`water.lua`): `want` = `carers_per_patient` (1) per patient, at least `carers_min` (2), at most
  `carers_max` (8; 0 switches the scaling off), plus `carers_urgent` (2) while a patient is over `thirst_alarm`. Missing
  caregivers join the **Orderlies** work detail through `act.work_detail('Orderlies', id, true, {select = true})` (the
  work details screen; a detail on "nobody does this" is set to "only selected do this"), at most `carers_per_run` (2) a
  daily run. Candidates (`M.carer_ok`): adult, no squad, no mood, no noble post, no MINE/CUTWOOD/HUNT labor (the tool
  specialists stay), not a patient, not a caregiver yet; idle ones first, then the nearest the hospital zone. `water` is an
  owner of `work_detail` (contract), `Orderlies` joins `A.TOOL_DETAILS`.
- Hysteresis: the kernel's own additions (persisted `m.water.cw`) leave one a run, `carers_hold_days` (14) after the last
  patient; members the player put in are never touched. A missing detail is asked again after a week.
- `patient_thirst` names the shortfall ("caregivers short: 3 of 7 wanted for 5 patient(s), 2 added to Orderlies now" or
  "could not add: ..."), its `q` leads with the recipe and keeps the cause (it was cut off at 200 bytes before).
- New class A event `PATIENT_DYING` at `dying_thirst` (60,000): units, thirst, caregivers/want/idle/added, citizens giving
  water, GiveWater/GiveFood jobs open/running, free buckets, hospital `ok|dry|none`, the cause; cadence rule (at once for a
  new patient or a changed state, else not before `dying_every` = 2 days and the wall wait). RULES section 7 row,
  CONTRACTS section 12, wake hint.
- BUG-034/040 rules unchanged: the dry-hospital removal, `hospital_out`, `bp sites hospital` near accepted water.

## Safety
SIEGE/BREACH: only a work-detail membership changes (a labor flag), no movement order; the adds are bounded per run and
by `carers_max`; nobody on a squad, in a mood, a miner/woodcutter/hunter or a noble is taken. A fort of 7: `carers_min` 2
of 7 adults, never a patient. A fort of 80: at most 8 caregivers. An old kernel state: `m.water.cw` absent = nothing of
ours to remove. A reload loses no member (persisted). No `Orderlies` detail: no write, the line says so.

## Tests
`tests/lua/test_water.lua` (the y497 replay: 5 patients, 4 caregivers, a served hospital -> 2 additions a run up to 7 and the
text; the bound `carers_max`, the scaling off; idle first/nearest and the exclusions; hysteresis; a missing detail; no
owner = no write; PATIENT_DYING with the state, the cadence, a dry hospital and no caregiver; the inspect view; the old
"present" text in the other tests now says "short" while 2 of 4 stand), `tests/test_a4_health.py` (schema, config
validation, RULES). Each new test fails on f17e2b3.

Related: BUG-034, BUG-036, BUG-040, BUG-008 (cadence), FR-34, notes 18, 24, 26(c), 63 of RUN11-offene-bugs-und-FR.md
