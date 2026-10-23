# BUG-094 `lint --config` accepts any value for economy.standing.from_phase
Status: fixed in the integration audit J3 commit (offline, live-untested): `fairplay.ECONOMY_LIM` knows a phase (`P0`..`P7`) and
refuses anything else
Severity: low (a typo in a config file reaches the kernel: a number there makes the standing-order task raise every game day;
the standing thread and cloth orders are then never made)
Found: 2026-10-23, integration audit J3 (every key added since f17e2b3 was set to a nonsense value in a copy of
config/baseline.json and config/reflex.json; this was the only new key every value passed)
Module: `dfpilot/fairplay.py` (`ECONOMY_LIM`, `economy_errors`), `lua/dfllm/economy.lua` (`phase_ok`, `T.stand`)

## Actual
FR-73's `economy.standing.from_phase` (default `P1`: the phase from which economy keeps its thread and cloth orders) was added
to config/baseline.json and read by `T.stand` through `phase_ok(K, from)`, which compares strings (`ph >= from`).
`ECONOMY_LIM['standing']` listed `amount` and `request_days` only, and `standing` is not in `ECONOMY_OWN`, so
`python -m dfpilot.lint --config` reported `config ok` for `from_phase: 5`, `null`, `true`, `"x"` or `"P9"`. A number
makes the comparison `'P3' >= 5` raise ("attempt to compare string with number") in `T.stand`; `run_slice` catches it
(`economy task stand: ...` in kern.log, `task_errs`) and goes on with the next task, once per daily run (a game day is 2.7 s
at timestream speed), and the standing thread and cloth orders are never made, the very orders FR-73 added.

## Fix
`ECONOMY_LIM['standing']['from_phase'] = 'phase'` and a `phase` branch in `economy_errors` (a string `P0`..`P7`). The Lua side
is unchanged (the shipped value is `P1`).

## Tests
`tests/test_j3_whole.py` (fails on c038ce9): nine nonsense values are refused, four phases pass. The keys added in this run
whose meaning was written down nowhere but in bug files (`care.far_check`, `mood_nook`, `mood_take`, `mood_nook_retry`,
`topple_win`, `topple_r`, `economy.slabs.trigger_ticks`, `scan_max`, `jam_min`, `standing.from_phase`) are in CONTRACTS section
9.17 now.
