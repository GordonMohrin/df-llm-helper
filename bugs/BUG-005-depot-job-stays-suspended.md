# BUG-005 the trade depot construction job is resumed every day and stays suspended, DEPOT_MISSING says "being built" for ever
Status: open
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

## Cause (suspected)
Something re-suspends the job after the resume (DF itself suspends construction jobs whose builder was interrupted by a
hostile or by "cannot reach"; the surface site at the shaft head is where armies and wild animals pass). The kernel does not
read the cancel reason.

## Fix proposal
Log the last cancellation reason of the job (announcement text for "Construct Building"), count resumes per job, and after
N repeats place the depot elsewhere (inside the entrance, off the army route) or raise a class A event with the reason.

Related: FR-43, BUG-004, BUG-009 (the same re-suspension hits every construction job, reproduced with workshops placed by hand)
