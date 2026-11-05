# BUG-477 PLAN STALE for years: follow's minimal plan failed (AUTO_FAIL) every year
Status: fixed (offline, live-untested)
Severity: high (the applied plan stood still y379 -> y388 on i1 and y386 -> y397 on i2 with no player)
Found: 2026-11-05, Run 16a i1 / 16b i2 (cli.log "minimal plan: fortcore: y372s0b1 (stage 3) stopped on breach:water ... parked; seasons[1].build[0] fortcore stage 3 @same would build on it: re-site first"); i3 got "PLAN MINIMAL (by follow)"
Module: `dfpilot/plan.py` (`auto_plan`), `dfpilot/wake.py` (`_check_plan`, unchanged)

## Actual
`_check_plan` fired every year (stale_apply_years 2, PEACE, `tried_y` per year), but `plan.apply_minimal` returned the check ERROR of one drafted build and applied nothing: AUTO_FAIL once a year, YEAR_REVIEW "PLAN STALE y379->y387" for ten years. i3 had no such ERROR and got the minimal plan.

## Root cause
`plan.auto_plan` cuts the draft to the builds `minimal_ok` allows (the refuge fortcore stage 3 among them), then adds the repairs the ERRORs name that `minimal_ok` allows. The repair of "stage 3 behind a parked stage 1" is a stage-1 re-site, which `minimal_ok` forbids, so the ERROR stayed and `apply_minimal` refused the whole plan. Only the raise path had the `_subset` fallback.

## Fix
`auto_plan`: when the minimal plan still has ERRORs after the repair rounds, take `_subset` (drop the new build whose removal leaves the fewest ERRORs, latest first, down to no new build at all): the plan follow applies is the error-free subset; the dropped ERRORs are `held` and the plan note and PLAN_AUTO message say "N ERROR held back". Without a subset (an ERROR independent of the new builds) the errors stay as before. The age rule is unchanged (`stale_apply_years` 2 = an applied plan two or more years old, PEACE, once per game year).

## Tests
`tests/test_bug474_477_f29ops.py` (subset used and held errors named; no subset keeps the errors).

## Live check
A fort whose minimal plan failed with "fortcore stage 3 ... parked": the next year's follow wakes PLAN_AUTO "follow applied the minimal plan (... 1 ERROR held back ...)" instead of AUTO_FAIL, and `status` loses PLAN STALE.
Open: the held ERROR (re-site the parked stage 1) is the player's / `plan propose`'s job; a fort in SIEGE or BREACH for a whole year still gets no automatic plan (PEACE only).
