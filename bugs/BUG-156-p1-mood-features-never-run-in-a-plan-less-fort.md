# BUG-156 The P1 mood features (mood shops `mood_ws`, mood stock, cloth floor, training weapons, standing orders) never run in a fort without a plan
Status: fixed (offline, live-untested)
Severity: high (Run 14 note 92: 151 of 453 citizen deaths were failed strange moods; a plan-less fort never got the mood guard)
Found: 2026-10-28, live test i4 (new bug 4): y717, pop 52 (47 adults), `PLAN NONE`, kernel phase P0 for good
Module: `lua/dfllm/economy.lua` (`phase_ok`, `M.phase_ok`, `M.planless`)

## Actual
`economy.phase_ok(K, 'P1')` compared the runner's phase with the feature's `from_phase`. `mood_shops` (the R0 blocker `mood_ws`), the mood stock,
the cloth floor, training, leather and the standing orders all start at P1. The runner advances a phase only when its deliverables pass; with no plan
applied nothing builds the P0 deliverables (fortcore pieces), so an adopted fort of 52 stayed at P0 and none of them ran (the tester had to cheat
the persisted phase to P1).

## Fix
`M.planless(K)`: no applied plan (persist `plan.plan` null) and at least `offices.mood_ws_pop` (20) citizens. `M.phase_ok` lets such a fort count
as P1 for the P1 features; P2 (metal) and P3 (glass) stay gated. A fort with an applied plan keeps the phase gate (its plan builds the shops).

## Tests
`tests/lua/test_care_live_i4.lua`: a plan-less P0 fort of 24 gets `mood_shops`, `phase_ok P1` true and `P2` false; 8 citizens or an applied plan keep
the gate (fails on main 2c0ffa3).

## Live check
A plan-less fort of 20+ citizens at P0 with a missing moodable workshop: after `offices.mood_ws_days` the R0 blocker `mood_ws` with its command;
`inspect what=orders` shows the cloth floor and the training orders.

## Not decided offline
Whether 20 citizens is the right threshold for the cloth floor and the training weapons too (it is the mood_ws one).
