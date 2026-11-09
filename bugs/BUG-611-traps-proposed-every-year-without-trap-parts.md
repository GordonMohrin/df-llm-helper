# BUG-611 `traps` proposed every year with no trap parts and no way to make them
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-09, Run 16a i1 Basementflew y426-y429 (`traps@S1` every year, round 37's `no stone traps` did not hold)
Module: `dfpilot/plan.py` (`noparts_reason`, `_gate_why`, `drop_impossible`, `stone_gate`, `hospital_table`), `lua/dfllm/economy.lua` (`M.state`), `dfpilot/schema.py`

## Actual
`traps` proposed every year with no trap parts and no way to make them.

## Root cause
BUG-586 gated the traps on `fort.nostone` (soil, `rock 0`, DF's denial). The fort had free boulders and no denial, but no free mechanism and no Mechanics workshop (or the stone orders queued behind 190 others): every trap waited for trap parts. The plan had no fact about the mechanisms.

## Fix
State `stock.mfree` (free trap parts) and `stock.mroute` (`plan_mech`'s route: `no stone`, `no Mechanics`, `ordered`, `stone`); `plan.noparts_reason` says why no trap can be built when none is free and the route is `no stone` or `no Mechanics`; `fort.noparts` gates `traps` (not the temple / cistern) in `drop_impossible` and `stone_gate`, and the hospital's new bench=0.

## Tests
`tests/test_bug607_612_f39_econ.py` (4)

## Live check
`plan propose` in a fort with `stock.mfree 0` and `mroute no Mechanics`: no `traps` build, the note names the parts.
