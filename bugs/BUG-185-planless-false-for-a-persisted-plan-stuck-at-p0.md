# BUG-185 A fort whose kernel holds an old plan stuck at P0 is never plan-less: the P1 mood features stay off (BUG-156 follow-up)
Status: fixed (offline, live-untested)
Severity: high (the fort BUG-156 was reported in still got no mood shops, mood stock, cloth floor or training)
Found: 2026-10-29, live test round 2, instance i4 (y723-y726, pop 52-54), confirmed by the skeptic re-check
Module: `lua/dfllm/economy.lua` (`M.planless`, new `M.plan_stuck`)

## Actual
`M.planless` returned false as soon as persist `plan.plan` was a table. The i4 kernel held a y712 plan doc (`phase_target` P0, notes "draft from
phases P0..P5"), persist `phase` P0 since tick 200668473 (about 92M ticks, many years). `status`/`brief` said `PLAN NONE` (they read plan.json,
which is absent), the kernel said "plan present", so `phase_ok(K,'P1')` and `mood_shops` stayed off while Masons and MetalsmithsForge were missing.

## Fix
`M.plan_stuck(K, doc)`: `'target'` when the doc's `phase_target` is a string `<= 'P0'` (the plan never aims at P1), `'stuck'` when persist
`phase.phase <= 'P0'` and `now - phase.since > M.PLAN_STUCK_YEARS` (1, the same year as brief's `STALE_SHOW`) game years. `M.planless` treats such
a doc as no plan; the population gate (`offices.mood_ws_pop`) and the P2/P3 gates are unchanged.

## Tests
`tests/lua/test_care_live_i4.lua` BUG-185: phase_target P0 -> plan-less; P2 target with P0 held 3 years -> plan-less; P2 target with P0 just
entered -> not; 8 citizens -> not (fails on b805745).

## Live check
i4 (Trussroads): read-only `economy.planless(K)` true, `phase_ok(K,'P1')` true; after `offices.mood_ws_days` status shows R0 `mood_ws` with the
missing shops' command.

## Not decided offline
Whether brief should also report the kernel's persisted plan (year, phase_target) so the two sides use the same fact.
