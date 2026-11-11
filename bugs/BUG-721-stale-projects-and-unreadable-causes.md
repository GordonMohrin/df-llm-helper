# BUG-721 Stale projects block slots for years (repair, long fights), 'no builder has taken it (no cause readable)', build_lost with no reason for one-tile pieces
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10/11, Run 16a i1 Basementflew y460 (repair rp184426767 'nothing stands' 1033 d), Run 16b i2 Whirledrampart y423-y430 (tavern 3315 d, bedrooms 2377 d, refuge_beds 1685 d set aside in a BREACH / SIEGE flicker of > 370 days; `c1a1c7fdbd44 ... no builder has taken it (no cause readable)` beside 27 unclaimed ConstructBuilding and 12 idle adults), Run 16a i1 `build_lost at build, missing bed x3` without a reason
Module: `dfpilot/plan.py` (`STALE_CANCEL_TPLS`, `STALE_FIGHT_MULT`), `dfpilot/wake.py` (`_check_stale`), `lua/dfllm/economy.lua` (`build_state` `rec.short`), `lua/dfllm/runner.lua` (`Q.lost_why`)

## Root cause
- follow cancelled stale projects only in PEACE and only the templates in `STALE_CANCEL_TPLS`: `repair` was not among them ('follow cancels traps, tombs and the other replaceable templates itself' did not hold), and a fort that never saw PEACE for a year (mammoth BREACH / SIEGE flicker) never cancelled anything.
- `economy.build_state`: with no labor, burrow, boxed-in, item or job-board cause the short answer was the literal 'no cause readable'.
- `Q.lost_why` (BUG-536) read only a multi-tile building (the depot); the one-tile pieces of a bedroom or hospital (bed, chest, table) lost on a wall, tree, stair or water tile said nothing.

## Fix
- `repair` is a stale-cancel template; outside PEACE / RECOVERY a project set aside `STALE_FIGHT_MULT` (5) times `plan.stale_project_days` (1500 d at the default) is cancelled too (`PROJECT_STALE` as before).
- `build_state.short`: 'no builder took it: no cause readable (labor n/m, items a/b, in burrow, not walled in); busy or no path: inspect workload, reach' (what was read, and the two causes left).
- `Q.lost_why`: 'N of M missing pieces stand on tiles that are no open floor (x,y,z tree (bed), ...)'; it goes into PROJECT_BLOCKED, the park event and the lost-cancel text (they already call `lost_why`).

## Tests
`tests/test_bug721_stale_fight.py` (7), `tests/lua/test_bug721_lost_reason.lua` (2), `tests/lua/test_economy_build_state.lua` (adapted text). i4 'bedrooms stalled for missing beds although 357-416 logs exist': no separate cause found in the logs; it is the BUG-705 case (logs on another walk group, 'Needs logs'), now named by the census and the cancel text.
Open: a stale project older than the limit in a short fight still waits; the real cause behind a clear-looking 'no builder' (busy builders, a job nobody can path to) is not read (the text says so); `refuge_beds` / `fortcore` stay announced, never cancelled.
