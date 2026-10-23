# BUG-044 The seal door 115,73,143 stayed open for 14 game years: its construction job was suspended again and again, nothing said why, nothing gave up on it
Status: fixed in 73b429d (offline, live-untested): SEAL_STUCK `wait` names the building, its job and who suspends it
(`economy.build_state`); a seal's door cells ignore the BUG-042 order cap (bounded per seal); a door still unbuilt
`seal_first.wall_days` (2) after SEAL_STUCK becomes a constructed wall where the citizens keep another way (SEAL_WALLED,
B); the live cause is not decided offline (below)
Severity: critical (loses citizens: sieges 13 and 14 cost 36 and 24 of them through this door and a second open
entrance; "the most expensive single failure of Run 11")
Found: 2026-10-18, Run 11 fort Kilrudrabed (site98), y483 summer d69 to y497, from the game session's notes 16, 21, 22
and 23 (`bugs/RUN11-offene-bugs-und-FR.md`; triage A1)
Module: `lua/dfllm/runner.lua:670-687` (measure_build), `:1549-1558` (orders), `:2470-2530` (Q.wait_why),
`:2548` (stuck_event); `lua/dfllm/economy.lua:6093-6097` (T.jresume), `:4769-4796` (T.jmake); `lua/dfllm/act.lua:1449-1461`
(job_resume)

## Actual (live, game session)
- The seal c1a14b92909f3d7801 (placed y483 summer d69) kept `1 way in without door or bridge: 115,73,143 floor` in the
  status for 14 game years; `SIEGE_END ... sealed 0 ticks` in siege 13 (y487 autumn), `on_station=0` and two open
  entrances (113,73,143 and 115,73,143) in siege 14 (y497 summer d23-29).
- Note 21: the ConstructBuilding job of the door was SUSPENDED, DFHack suspendmanager's text was "Blocks another build
  job"; resumed by hand (`job.flags.suspend=false`) it was suspended again at once; after `disable suspendmanager` and a
  resume the building site vanished ("none") and the project placed it anew.
- Note 22 (correction): with suspendmanager disabled the job was suspended again too (8 reads, 10 s apart): "not only
  suspendmanager". The fort held 110 open ConstructDoor orders.
- Status showed only `stalled`; SEAL_STUCK had no `wait` for a build stage.

## Cause (proved from the code at f17e2b3; the live cause among the candidates is not decided offline)
1. **The kernel suspends nothing.** `grep "suspend = true"` over `lua/dfllm` finds no write; the only write of the flag is
   `act.job_resume` setting it false (act.lua:1461). So a suspended job comes from DFHack (buildingplan, suspendmanager)
   or from DF itself (the builder's cancel). The kernel's own "construction resuspended" is no candidate.
2. **A planned building's job is suspended by buildingplan itself until its items are attached.** economy knows it:
   T.jresume resumes only jobs that are neither planned nor kept (economy.lua:6097). A resume by hand on such a job is
   undone at once, with suspendmanager disabled too: exactly note 22's observation. A planned door waits for a door
   item, and the door item is what the fort did not make (candidates 3b below).
3. **What the code shows whoever suspended it:**
   a. `measure_build` returns `'done'` for ever while one planned building stands (runner.lua:687): no timeout, no
      escape, no report. A stuck door stays a stuck door; the seal keeps `stuck` and the others run beside it (BUG-037),
      the way in stays open.
   b. The door's manager order is skipped while `orders_cap` (10) open ConstructDoor orders stand (runner.lua:1558, the
      BUG-042 cap): the fort had 110, so a seal placed under them got **no door order of its own**, and T.jmake counts
      those 110 orders as made (economy.lua:4796, `piece_orders` 4686: an open order counts when rock is left for all
      the rock orders) and orders none either. A planned door waiting for an item that no order of its own makes, behind
      110 older orders (rock-short in Run 11, unvalidated until y471) fits every live number; it is a code defect
      whether or not it was this fort's cause.
   c. `Q.wait_why` had no build branch (runner.lua:2470-2530): SEAL_STUCK `wait` could say a chop nobody takes or a piece
      no citizen reaches, never the job, its suspension or the missing item.
   d. The building site "none" before the project placed it anew is the runner's one re-apply (measure_build lost > 0,
      `R.ra`): the planned building was gone (DF dropped it after the forced resume), quickfort placed it again, it
      waited again.

## Fix
- **`economy.build_state(x, y, z)`** (read-only): the building on a tile, its ConstructBuilding job and who keeps it
  suspended: `buildingplan` (planned: `need` = what it waits for with the free items of that class and the open orders of
  the piece's job, validated or not), `suspendmanager` (`isKeptSuspended` plus its own description), else `DF` (the latest
  CANCEL_JOB report near the tile, the forbidden and other items on it, else "no cause readable"); `work` = a builder is
  assigned; one-line `line`.
- **SEAL_STUCK `wait`** for a build stage: `door 115,73,143: job 4711 suspended by buildingplan: waits for door x1 (0
  free, 110 ordered, 100 not validated)`; also in the msg and kern.log.
- **Orders:** a seal's door/hatch cells ignore `orders_cap`, at most `orders_seal` (12) door/hatch items for one seal
  project in all (m.runner `so`): retries and remakes cannot flood the manager again; other projects stay capped.
- **The bounded fallback (`Q.stuck_walls`, own pcall, once a game day per seal):** a door cell of the current build stage
  that is still not built `seal_first.wall_days` (2) after SEAL_STUCK, in PEACE, with no reflex lockdown holding and
  nobody building it, is replaced by a constructed wall on the same tile: the planned door is removed (quickfort `undo`,
  the player's remove building; verified, three tries), the cell becomes `Cw` in `bp.<id>` (materials door -> wall), the
  chunk is applied again (a wall needs no door item: buildingplan takes any building material), SEAL_WALLED (B) once,
  PROJECT_DONE names it (`door stuck at x,y,z: wall instead`). Only where the last entrance check (`seal.opening_ways`, at
  most `wall_age` 60 days old) shows the citizens another way: the tile lies beside the door or bridge of its own opening,
  or another opening has a door or a bridge. Otherwise the door stays and kern.log says why, once per reason: the only way
  in or out is never walled (a fort of 7 with one entrance keeps its door and its SEAL_STUCK). Hatches (stairs), walls and
  grates are never replaced. Config `runner.seal_first.wall` (true) / `wall_days` (2, 0-60).
- The seal-first count keeps its own pcall (BUG-037); the fallback has another: a fault costs only the fallback.

## Not decided offline
- **Which candidate was the live cause** (buildingplan waiting for a door item that nobody makes; suspendmanager; DF's
  builder cancel). Decides it, read-only, on demand: `dfllm cmd inspect '{"what":"workload","key":"build:115,73,143"}'`
  (the building, its job, `who` keeps it suspended, the missing item with the free ones and the open orders), and the
  next SEAL_STUCK of such a door carries the same as `wait` (`dfllm events --type
  SEAL_STUCK --limit 1`, kern.log `seal first: ... built nothing for N days`): `suspended by buildingplan: waits for door
  x1 (0 free, N ordered, M not validated)` is the door-item case (then `dfllm cmd inspect orders` shows the ConstructDoor
  orders, `validated`, their material and "Needs rock" cancels; `inspect workload` `construction.missing`);
  `suspended by suspendmanager: <text>` is note 21; `suspended by DF: cancelled "..."; N forbidden` is BUG-009's item on
  the site (T.jsite unforbids the forbidden ones daily; `other` items and corpses it cannot).
- **Does quickfort `undo` remove a planned (unbuilt) door?** The plug code uses it on built doors and hatches
  (runner.lua `p0.free`); a planned one is the same call on the same key. If DF keeps the planned door the runner tries
  three times (one a game day), logs `door x stays a door: quickfort undo did not remove the planned door (3 tries)` and
  leaves the door as it was. Decides it: kern.log after SEAL_WALLED, then `dfhack-run lua "local b=dfhack.buildings.findAtTile(X,Y,Z);
  print(b and df.building_type[b:getType()])"` (Construction = the wall is planned).
- **suspendmanager may suspend the wall too** (it is a construction): then `wait` of the next SEAL_STUCK says so and
  `jobs.release {"preventblocking":false}` (DECISION_NEEDED `preventblocking` after `held_days`) is the lever; the kernel
  does not switch it by itself (a global option of the fort).

## Tests
`tests/lua/test_runner_seal_door.lua` (SEAL_STUCK `wait` by cause; the order cap; the fallback and its refusals: the only
way, a builder at work, ALERT, lockdown, config, an old or unknown check, a failing undo, hatch and wall pieces),
`tests/lua/test_economy_build_state.lua` (the four causes), `tests/lua/test_seal_ways.lua` (a tile beside the door, a plain
gap, a narrow opening, the only opening), `tests/test_bug044_files.py` (SEAL_WALLED and `parts` in the contract, the
config keys). Each fails on f17e2b3.

## Related
BUG-005, BUG-009 (forbidden items on a site; the same "resume undone" symptom), BUG-037 (a stuck seal yields its slot),
BUG-041 (a seal that waited on a shrub), BUG-042 (the 110 ConstructDoor orders and their cap), BUG-045, BUG-046, notes 42
and 45 (stone door orders without jobs, EngraveSlab orders jamming the masons: other packages), DECISIONS 4 and 11
