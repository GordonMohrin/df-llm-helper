# BUG-546 Link jobs of the refuge levers hang for more than 1000 days, gate never re-issues them, link_stale offers no command
Status: fixed (offline, live-untested); open: the live effect of removing a link job
Severity: high (O1 and B2 stay unlinked: no pull from the refuge, PERIMETER OPEN, GATE_FAIL outside_alert)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y397/y402/y404 (`runs/run-16d/FR-BUGS.md` lines 361, 379, 387; `E:/DF-test4/dfllm-runtime/r16d4-trumpetrealms-site97/events.jsonl`: LEVER `link O1` jobs 211617 / 211635 at tick 156072169 / 156073369, nothing after for 4 million ticks)
Module: `lua/dfllm/gate.lua` (`M.link_watch`, `links`), `lua/dfllm/act.lua` (`cancel_link_job`, `labor_set`), `lua/dfllm/economy.lua` (`M.mechanic_labor`), `lua/dfllm/readiness.lua` (`ask_reflevers`)

## Actual
`inspect defense`: O1 linked 0 on the entrance and refuge levers, B2 17828 linked 0. gate.lua `links()` skips a lever with `link_pending` (a LinkBuildingToTrigger job on it); the job waits forever (a Mechanic does not come, nobody holds the Mechanics labor, or its two mechanisms are gone). BUG-513 added the diagnosis `link_stale` ("needs a dwarf with the Mechanics labor and a Mechanics workshop", 446 days) but no command and no repair.

## Root cause
`gate.lua` `links` (the `not link_pending(lv)` guard): a pending job is never looked at again; there is no age limit, no re-issue, and nothing makes sure a Mechanic exists (economy requests the Mechanics workshop, but takes no labor action). `readiness.ask_reflevers` gave `link_job` / `link_stale` the plain text and `cmds = nil`.

## Fix
`gate.link_watch` (each pass of `links`, only in PEACE / ALERT / RECOVERY, once the bridge stands): a link job queued `LINK_MECH` (1,200 ticks) asks `economy.mechanic_labor` (once per LINK_MECH): if no adult citizen off duty holds MECHANIC, the best candidate (idle first, then Mechanics skill; no soldier, patient, mood or noble) gets it through the new `act.labor_set(unit, 'mechanic', true)`. A job queued `LINK_REISSUE` (14,400 = 12 days, = LINK_STALE) with no worker is removed by the new `act.cancel_link_job(lever)` (only unworked LinkBuildingToTrigger jobs of that lever; a job with a worker stays, a pull never goes), the lever reads `built` on the next pass and `act.link_lever` links it again with the mechanisms that stand (LEVER `relink <bridge>`, kern.log). A refusal ("needs 2 free mechanisms") is the BUG-513 `unlinked` cause. `readiness` `link_stale` (a job a dwarf holds that is still not done) now carries `cmds`: `trade.want {"add":["mechanism","stone"]}` while fewer than 2 mechanisms are free, else `inspect workload`. Lint: `removeJob` also allowed in `cancel_link_job`, labor writes also in `labor_set` (mechanic on, farm off only).

## Tests
`tests/lua/test_bug546_link_reissue.lua` (the siege / drill traffic test in the world of test_bug543_raise_traffic: a pacer who steps onto B1 the tick it moves, beside a re-issued link: nothing pulled, no bridge moved, nobody crushed; a link job with a worker stays; BREACH with citizens and soldiers walking over O1 / B1 / B2 and a stale job: no link job touched, all three rise; after a re-issue a lever-up of B1 waits for the pacer and rises once, no other bridge pulled), `test_bug546_547_acts.lua` (the two acts on the real act.lua), `test_bug544_547_stone_manager.lua` (`mechanic_labor`), `test_bug513_refuge_levers.lua` (adapted: the stale case is a job a dwarf holds; the command is asserted), `tests/test_bug544_547_f35.py` (lint, ownership).

## Live check
A refuge-lever link job older than 12 days with no worker: kern.log "link job unworked for N days, taken down", LEVER `relink B1`, then `link B1` with a new job; `Mechanics labor on for unit N` when nobody had it.
Open: whether `removeJob` on a link job frees the two attached mechanisms at once (act.link_lever picks free ones; with fewer than 2 it refuses and says so, cause `unlinked`).
