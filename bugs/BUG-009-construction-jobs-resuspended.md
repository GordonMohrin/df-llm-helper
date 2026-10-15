# BUG-009 construction jobs are suspended again within 5 s of every resume, new buildings are never built
Status: fixed in 9b9dcdc, 7006350 (offline, live-untested). Live (677bc3e): CONFIRMED (see BUG-004).
Severity: high (workshops, a bed, the trade depot and the coffins stay unbuilt; 16 of 17 civilians idle; every caravan lost; FR-16 "resume" has no effect)
Found: 2026-10-15, Run 9 save autosave 1 (y363-367), dfpilot main 3edc277, live test by Claude
Module: `lua/dfllm/economy.lua:2999` (FR-16 daily resume); the cause is items blocking the site (below)

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

## Fix proposal
In the daily FR-16 pass, for every suspended ConstructBuilding job scan the building footprint (x1..x2, y1..y2, z) for items on the ground:
unforbid forbidden ones (they are the usual blockers; mood-reserve holds are marked by care and skipped), and name the rest (corpses, other
items) in JOBS_SUSPENDED (`why: item blocking site: N forbidden, M other`). Do not report "resumed N" when the flag returns the next frame.
Also: whoever forbade 41 items on the depot site (looks like loot and cloth of a siege, forbidden by the kernel's own pass or by DF for the dead).

Related: BUG-004, BUG-005, FR-16

## Fix (9b9dcdc, 7006350, offline)
- New `snapshot.items_at(x0, y0, x1, y1, z)`: the loose items on the revealed tiles of a footprint (map block item
  lists; hidden tiles skipped).
- economy's daily FR-16 pass (tasks jobs, jsite, jmat, jfree, jresume, jcheck, jmove): for every suspended
  ConstructBuilding job (PEACE/RECOVERY) the footprint is scanned; forbidden items are unforbidden (`act.item_flag`,
  60 a day); care's mood-reserve holds (`care.held_ids`), corpses and dead dwarves' items (burial's), merchant goods
  and the job's own materials are skipped; the rest counts as other. JOBS_SUSPENDED names the reason
  (`item blocking site x2 ...; on the sites 41 forbidden (41 unforbidden), 2 other`). A resume is verified a frame
  later: a job suspended again counts as `resuspended`, not `resumed`.
- care's mood reserve never forbids an item on the footprint of a building not built yet and lets go of one it holds
  there.
- Who forbade the 41 items on the depot site: not the kernel. Its only `forbid=true` write is care's mood reserve,
  which takes items only from stockpiles inside Kern+ and only of its classes (boulders, logs, bone, shell, leather,
  cloth, thread, gems, bars), never BLOCKS; military's loot pass and economy only unforbid. Blocks and cloth on the
  razed surface depot fit the depot's own blocks and the dead invaders' gear, which DF's standing orders (forbid the
  items of the dead) leave forbidden.
- Live check: on the Run 9 save the four stuck sites (42,62,109), (42,59,109), (69,44,118), (57,73,110) lose their
  forbidden items within a game day and get workers; JOBS_SUSPENDED shows `suspended again` 0.
