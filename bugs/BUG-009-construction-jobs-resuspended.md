# BUG-009 construction jobs are suspended again within 5 s of every resume, new buildings are never built
Status: open (cause found 2026-10-15: forbidden items lying on the building footprint, see Cause)
Severity: high (workshops, a bed, the trade depot and the coffins stay unbuilt; 16 of 17 civilians idle; every caravan lost; FR-16 "resume" has no effect)
Found: 2026-10-15, Run 9 save autosave 1 (y363-367), dfpilot main 3edc277, live test by Claude
Module: `lua/dfllm/economy.lua:2999` (FR-16 daily resume); the cause that re-suspends is not yet known

## Reproduction
Placed with quickfort: a Masons workshop (42,59,109), a Still (42,62,109); already in the save: Trade Depot (69,44,118), Bed (57,73,110).
All four have a construction job with `flags: suspend`, no worker, materials attached (`items 3 / 1 / 1 / 1`), site reachable.

```
$ lua: set j.flags.suspend=false for these jobs, then read the flags every 5 s (6 reads)
TradeDepot@69,44 susp=true worker=false items=3 stage=0/3 | Bed@57,73 susp=true worker=false items=1 stage=0/1 |
Workshop@42,59 susp=true worker=false items=1 stage=0/3 | Workshop@42,62 susp=true worker=false items=1 stage=0/3
(identical in all six reads)
$ dfhack-run disable suspendmanager      -> "suspendmanager is disabled"; repeat the resume + 6 reads: identical, all still suspended
```
Kernel side: `JOBS_SUSPENDED construction jobs: 11 suspended, 2 resumed ... (every game day for 30+ minutes)`, later
`25 suspended, 4 released, 21 planned (buildingplan: waiting for materials x21)`. `inspect what=workload`: `16 of 17 adults without a job`.
All adults have BUILD_CONSTRUCTION and MASON enabled (34 of 35, Lua), no alert burrow confinement (`alert no confinement`).

## Cause (confirmed live)
Forbidden items lie on the footprint of the planned buildings. The builder cancels with "Item blocking site" (visible in the cancel list of
`inspect what=workload` and in the announcements) and DF suspends the job again; forbidden items are never hauled away, so it never ends.
Measured on the four stuck sites: Still (42,62,109) 3 forbidden items (TOOL, 2 SLAB), Masons (42,59,109) 3 forbidden TOOLs, Trade Depot
(69,44,118) **41** forbidden items (BLOCKS, CLOTH ...), Bed (57,73,110) 1 forbidden PANTS.
Test: unforbid the 48 items on those footprints and clear the suspend flags -> within 10 s the depot, the bed and both workshops had
workers; after 40 s both workshops were at stage 2/3 (`watchjobs`: `susp=false worker=true`).
A forced `dfhack.job.addWorker` without unforbidding did nothing: the worker was dropped within 6 s.

## Not the cause
suspendmanager (disabled, same result); items forbidden (blocks: 250 free); labors; reachability (`canWalkBetween` true).

## Suspects
buildingplan keeps the jobs of planned buildings suspended; DF re-suspends a job when a builder fails to path; a burrow or work-detail
restriction on the builders; the kernel itself (acts on construction jobs from `economy`).

## Fix proposal
In the daily FR-16 pass, for every suspended ConstructBuilding job scan the building footprint (x1..x2, y1..y2, z) for items on the ground:
unforbid forbidden ones (they are the usual blockers; mood-reserve holds are marked by care and skipped), and name the rest (corpses, other
items) in JOBS_SUSPENDED (`why: item blocking site: N forbidden, M other`). Do not report "resumed N" when the flag returns the next frame.
Also: whoever forbade 41 items on the depot site (looks like loot and cloth of a siege, forbidden by the kernel's own pass or by DF for the dead).

Related: BUG-004, BUG-005, FR-16
