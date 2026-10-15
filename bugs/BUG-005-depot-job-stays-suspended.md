# BUG-005 the trade depot construction job is resumed every day and stays suspended, DEPOT_MISSING says "being built" for ever
Status: fixed in 9b9dcdc (offline, live-untested). Live (677bc3e): CONFIRMED. Trade depot stands (67,42,118) 3/3; no DEPOT_MISSING since the reload.
Severity: high (every caravan is lost: Catten and Muboomon came at least four times in this session and left without trading)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/economy.lua` (depot keeper, FR-43; job release FR-16)

## Expected
The depot keeper gets a depot built, or says why not and moves it.

## Actual
```
NO_DEPOT: caravan without a trade depot: The merchants need a trade depot to unload their goods.
DEPOT_MISSING: caravan from Muboomon on the map and no trade depot stands (one is being built)
JOBS_SUSPENDED ... 11 suspended, 2 resumed ... (every day)
```
Lua on the depot job: `flags suspend,noise,quality`, `items 3` (three BLOCKS at the site (69,44,118), `forbid false`), `stage 0/3`,
site reachable from inside (`canWalkBetween` true). `suspendmanager: enabled but not suspending blocking jobs`. The job is
resumed each day (the "2 resumed" are the depot and a bed) and found suspended again the next day; nobody builds it.

## Cause (confirmed, see BUG-009)
41 forbidden items (BLOCKS, CLOTH ...) lie on the depot footprint; after unforbidding them the depot job got a worker within 10 s. The text below was the first guess.

## Earlier guess
Something re-suspends the job after the resume (DF itself suspends construction jobs whose builder was interrupted by a
hostile or by "cannot reach"; the surface site at the shaft head is where armies and wild animals pass). The kernel does not
read the cancel reason.

## Fix proposal
Log the last cancellation reason of the job (announcement text for "Construct Building"), count resumes per job, and after
N repeats place the depot elsewhere (inside the entrance, off the army route) or raise a class A event with the reason.

Related: FR-43, BUG-004, BUG-009 (the same re-suspension hits every construction job, reproduced with workshops placed by hand)

## Fix (9b9dcdc, offline; the main cause is BUG-009)
- The depot's footprint is cleared like every other site (BUG-009).
- Resumes are counted per job (`p.jres`: resumes, resumes that did not hold, the cancel reason from CANCEL_JOB
  reports at the site). After `jobs.fail_alarm` (3) failed resumes DECISION_NEEDED `build_blocked` (A) names the job,
  its position and the reason (repeat rule of BUG-008).
- After `jobs.depot_move_after` (5) failed resumes, in PEACE and without a fortcore manifest depot, the depot moves
  inside the entrance, off the army route: a 5x5 inside a 7x7 of revealed roofed floor within 12 tiles of an entrance
  (seal.entrances, its level and 2 below), at least 3 tiles from every entrance and the manifest approach, reachable,
  no items on it; `runner.depot_move` cancels the stuck depot (project undo, else quickfort undo of the planned
  building) and queues the new one. At most every 28 days; `inspect workload` `construction.depot_move`.
- DEPOT_MISSING says "being built" only while the planned depot progresses (job running with a builder, or stage > 0);
  else "the planned one at x,y,z does not progress: <reason>, N resumes failed" (`stalled: 1`, `why`).
- Live check: a caravan without a built depot: DEPOT_MISSING text; the depot site cleared and built; on a blocked site
  the move after 5 failed days.
