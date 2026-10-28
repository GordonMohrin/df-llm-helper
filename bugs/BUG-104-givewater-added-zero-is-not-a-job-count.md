# BUG-104 "GiveWater added=0" with buckets and caregivers present: the number is not a job count, and the line never says why no job runs
Status: fixed in the M1 commit (offline, live-untested): patient_thirst and PATIENT_DYING name why nobody carries water, in counts
(`jobs 0 open/0 running, carers 95 (75 idle, 12 reach), buckets 86 free of 100`) and a verdict (`alert`, `noreach`, `stuck`, `open`,
`nojob`, `run`); the cause of the missing jobs themselves is live data (see "Not decided offline")
Severity: high (repeated thirst deaths of patients behind a line that said everything was present)
Found: 2026-10-25, Run 14 (region2-site90), game session note 79 and post-mortem line "caregivers 95 of 5 wanted (75 idle), 0 giving water"
Module: `lua/dfllm/water.lua` (`finish`, `M.carers`, `M.give_jobs`, new `M.job_scan`, `M.give_diag`)

## Actual
DECISION_NEEDED patient_thirst said "water, buckets and caregivers present: check the GiveWater jobs" with `added=0`, 86-119 buckets and
7-9 listed caregivers; the patient and the caregivers were in one walk group; patients died of thirst, 2-3 per season. The note's
hypothesis: an error in the kernel's own job-add path.

## Cause (proven from the code at 32994bb)
1. **There is no job-add path.** Nothing in the kernel creates a GiveWater job (fair play: jobs are the game's; `rg GiveWater lua/`
   finds reads and texts only). `added` of the DECISION_NEEDED is `#cs.added` (water.lua:1275): the **caregivers `M.carers` put into
   the Orderlies work detail** this run (water.lua:1103-1159, through `act.work_detail`). It is 0 whenever `have >= want`
   (water.lua:1106-1121: `want = max(carers_min, patients * carers_per_patient)` + `carers_urgent`, at most `carers_max` 8) or the
   pool is empty. With 95 citizens holding FEED_WATER_CIVILIANS (`carer`, water.lua:243: an adult with the labor, nothing else)
   `have` is 95 against `want` 5: `added=0` is the right answer, and says nothing about jobs.
2. **The default cause is a statement without a test.** `why` is `'water, buckets and caregivers present'` (water.lua:1225) whenever
   none of the listed tokens fired: no hospital zone, dry hospital, no accepted water, `r.free + fixed == 0` (1214), `after == 0` or
   `cs.want > after`. The code never asks whether the caregivers reach the patient (walk group, civ alert burrow), whether a GiveWater
   job exists, runs or stands open without a worker, and the carers it lists are the first eight of the census (water.lua:1231), not
   the available ones. "Present" meant "counted".
3. **The job census was a bare count.** `M.give_jobs` (water.lua:1078-1099) counted open and running GiveWater/GiveFood jobs, only for
   PATIENT_DYING, with no age: a job open (no worker) for days could not be told from one created a moment ago, and a fort
   whose game posts none looked like one whose caregivers are busy. (A job's `pos` is not a marker: the note itself records that a
   running job may have pos -30000, and that deleting such a job by hand killed a patient.)
4. **No cap is shared with another counter:** `mine >= carers_max` (water.lua:1121) only blocks a further addition when the added
   citizens hold no labor; it is reported (`out.err`), not the cause of added=0 here.

## Fix
- `M.job_scan(p, now, days)` reads the job list once a run while a patient lies in a bed: GiveWater (water) and GiveFood open/running
  counts, and the ages of the open GiveWater jobs (`p.gj`, job id -> first tick seen, at most 60, forgotten when the job is taken,
  done or gone); `stuck` = open for `give_stuck_days` (2, config) or more.
- `M.give_diag` (only while a patient is over `thirst_alarm` or `dying_thirst`): the verdict `key` and the counts. The first that holds:
  `alert` (civ alert on, the thirstiest patient outside the burrow it holds the citizens in), `noreach` (no caregiver walks to him:
  `snapshot.reach`, unknown counts as reaching), `unreadable`, `stuck`, `open` (jobs open, none running), `nojob` (the game posts none),
  `run`. Text: `the game posts no GiveWater job; jobs 0 open/0 running, 5 idle, 6 reach; buckets 6 free of 6`.
- patient_thirst: the verdict leads the cause (`why`), `q` starts with it and the counts, the ids come last (the text is cut at 200
  bytes); new fields `open`, `run`, `stuck`, `reach`, `idle`, `key`. PATIENT_DYING: `stuck`, `reach`, `key`; a changed `key` is news
  (cadence). A dry hospital keeps its recipe (delete the zone, BUG-034) and its causes.
- kern.log: the PATIENT_DYING line carries the counts.
- `added` is documented as what it is (CONTRACTS, DECISION_NEEDED row).

## Not decided offline
- **Why the game posts no GiveWater job** with caregivers and buckets present. The new line says it (`nojob`, `open`, `stuck`) but
  not why. Read-only live data that decides it: a patient in `inspect what=hospital` (the zone, the location's supplies), the job
  list entries of type GiveWater / GiveWater2 (`job.flags`, `job.pos`, `job.general_refs`, worker) for ten days, the patient's
  `unit.job.current_job` and `unit.health.flags.needs_healthcare`, whether the patient lies inside the hospital zone, and
  `dfhack.maps.getWalkableGroup` of the patient and of the water source.
- Whether the civ alert burrow confines caregivers the way the `alert` verdict assumes (Run 14: the hospital lay outside Kern+ and the
  alert sent everybody there: kern.log "8 patients ... 0 GiveWater").
- Whether a bucket must be free for the job (the kernel's long-standing assumption, water.lua header).

## Tests
`tests/lua/test_water_m1.lua` (7 BUG-104 tests: no job posted, open and stuck, running, no reach, civ alert, PATIENT_DYING news,
no free bucket in counts) and `tests/test_m1_care.py` (schema, config, contract). All fail on 32994bb.

Related: BUG-034, BUG-054, BUG-056, BUG-103, BUG-106
