# BUG-419 follow's auto-placement after PLAN_EXHAUSTED placed a wet fortcore (score 0, aquifer)
Status: fixed (offline, live-untested)
Severity: high (Run 16b i2 Ostgate y399: 18 dig chunks of a core in four aquifer levels; the player cancelled it)
Found: 2026-11-05, `runs/run-16b/FR-BUGS.md` ('follow setzt nasses Fortcore', event #5420), main b4087f4
Module: `dfpilot/wake.py` (`_place`), `dfpilot/plan.py` (new `wet_core_guard`)

## Actual
After PLAN_EXHAUSTED P0 follow sent `bp.place tpl=fortcore stage=1 site=S1`; S1 was `66,56,131 rot3`, `water 15 steps, aquifer at z123,z126,z127,z130`,
score 0. Every ranked fortcore site of that world was wet; `bp.place` takes the best free site whatever its score.

## Cause
`wake.Follower._place` (starter and request jobs) sent `bp.place` with `site=S1` for every template without looking at the ranking of the
fortcore: `cmd.place` only falls back to a shallower core when the placement raises (BUG-364), a wet-but-free site raises nothing. The aqshaft route
of BUG-412 lives in `plan propose` only; follow never consulted it.

## Fix
`plan.wet_core_guard(save_dir, params, snap)`: for a fortcore stage 1 (not retrofit, not `p.aquifer`) at a ranked label `S<k>`, the best free site
is wet when its score is 0 or its reason line names `aquifer at z..`. Then a shallower core (`cmd.shallower_core_sites`, BUG-364) with a dry best
site is used (params get that `depth`); else nothing is placed: `BpError` (-> one AUTO_FAIL wake) saying why - with the aqshaft route (BUG-412) free:
"`dfllm plan propose` drafts aqshaft@x,y then fortcore p.aquifer=pass depth=N at <anchor>"; without: "no aqshaft route exists (<reason>)"; with
`plan.surface_core` on: the surface core is the alternative. `wake._place` calls it before `bp.place`; stage >= 2 (`same`) and `p.aquifer=pass`
placements are not judged. A ranking that cannot be read leaves the placement to `cmd.place` (its own error).

## Tests
`tests/test_bug418_419_requests_wet_core.py`: aquifer world -> `(None, reason with the aqshaft route)`; no route -> `no aqshaft route exists`; a dry
world places as before; `Follower._place` of a wet starter core sends nothing and fails with BUG-419, stage 2 `same` still goes out.

## Open
- follow does not place the aqshaft + fortcore pair itself; the PLAN_EXHAUSTED starter waits for the player's/auto plan (`plan propose`).
  AUTO_FAIL repeats with every PLAN_EXHAUSTED while the situation lasts.

## Live check
A region with an aquifer under every core site: PLAN_EXHAUSTED P0 -> `AUTO_FAIL fortcore: BUG-419 ...` instead of a core project in the aquifer;
`dfllm plan propose` then drafts aqshaft + fortcore aquifer=pass.
