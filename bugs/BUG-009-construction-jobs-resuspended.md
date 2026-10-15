# BUG-009 construction jobs are suspended again within 5 s of every resume, new buildings are never built
Status: open
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

## Not the cause
suspendmanager (disabled, same result); items forbidden (blocks: 250 free); labors; reachability (`canWalkBetween` true).

## Suspects
buildingplan keeps the jobs of planned buildings suspended; DF re-suspends a job when a builder fails to path; a burrow or work-detail
restriction on the builders; the kernel itself (acts on construction jobs from `economy`).

## Fix proposal
Find who sets the flag (a one-shot hook on `job.flags.suspend` writes, or read the job's `cancel` history), log it in JOBS_SUSPENDED
(`why: re-suspended by X`), and do not report "resumed N" when the flag is back on the next frame.

Related: BUG-004, BUG-005, FR-16
