# BUG-435 Projects set aside for 300-900 days for ever (traps, tombs, fortcore waiting for trapparts)
Status: fixed (offline, live-untested)
Severity: medium (nine projects clogged the brief; the traps never came: P5 'waits for drill' never freed armour and traps)
Found: 2026-11-05, Run 16d i4 Mazelanterns y401 (`runs/run-16d/FR-BUGS.md`): traps 912 d, tombs 461 d, fortcore 341 d, "waits for trapparts"; Run 16c i3 Yawninggilt tombs.build "waits for coffin"
Module: `lua/dfllm/runner.lua` (`Q.stale_scan`), `lua/dfllm/economy.lua` (`plan_mech`, `jneed`), `dfpilot/wake.py` (`_check_stale`), `dfpilot/plan.py` (`stale_projects`)

## Actual
The runner sets a project aside after `idle_days` (30) without progress (BUG-328) and then leaves it for ever: the announcement is made once. Its missing material was never
ordered either: `economy.plan_mech` counted only the mechanisms the lever gates need (`mech_need`), so planned traps that wait for `trapparts` (mechanisms) had no order at all.

## Root cause
`runner.lua Q.idle_scan` (BUG-328) has no end for a set-aside project ("never cancelled by the kernel"); `economy.lua M.jneed/plan_mech` ignored the `trapparts` class of `T.jmat`.

## Fix
- The missing material is ordered: `jneed` keeps the `trapparts` class (none free or forbidden), `plan_mech` adds it (at most `MECH.max_traps` 12) to the lever need: ConstructMechanisms in stone at a Mechanic's workshop
  (`max_jobs` 4 at once), a missing workshop is requested (`why=gear`), no stone asks the caravans for mechanisms.
- `runner.lua Q.stale_scan`: `runner.queue.stale_days` (300, 0 = off) without progress: PROJECT_BLOCKED (A) `why=stale` with `idle` days, what it waits for (`parts`) and the commands (`cmd`), again every
  `stale_every` (90) days. The kernel cancels nothing (an undo removes built work; the bp file lives on the Python side).
- `wake.py _check_stale` (follow, PEACE, not with --no-auto): `state.proj` rows `set aside N d` with N >= `plan.stale_project_days` (300, 0 = off; `fairplay.PLAN_LIM`) of the replaceable templates
  (`plan.STALE_CANCEL_TPLS`: traps, tombs, bedrooms, dining, tavern, temple, gallery, office, barracks, hall, workshops, depot, captives) get a plain `bp.cancel` (drops only what is not built) and `retire`
  (file to `bp/.cancelled`), wake reason PROJECT_STALE with project, template, days and the reason; `plan propose` draws the template again. The core, seals, water, supply and refuge builds are never cancelled here.
  A refused cancel is tried again after 6 h.

## Tests
`tests/lua/test_bug434_435.lua` (trap parts order, stale announcement and its cadence, off), `tests/test_bug434_436.py` (`stale_projects`, follow cancel + retire, wake registry).

## Live check
A set-aside traps project: kern.log `... stale: set aside N d`, `dfllm cmd inspect what=orders` shows `dfllm:mech`; after 300 d follow logs the cancel in cli.log and PROJECT_STALE wakes; the next `plan propose` lists the template again.
Open: tombs wait for a coffin (care's provisioner, FR-61), not mechanisms: they are cancelled and redrawn, the coffin supply is a separate gap. A fortcore set aside for ever is only announced (Gordon decides).
