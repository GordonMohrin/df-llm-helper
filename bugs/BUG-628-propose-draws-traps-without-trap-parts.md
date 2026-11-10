# BUG-628 `plan propose` still draws `traps@S1` while no trap part is free (the gate of round 39 did not reach the plan)
Status: fixed (offline, live-untested)
Severity: medium (a traps project hangs at "waits for trapparts" for years)
Found: 2026-11-09, Run 16a i1 Basementflew y455 (propose drew traps@S1 again with the mechanisms missing; BUG-611 in round 39)
Module: `dfpilot/plan.py` (`noparts_reason`, `check`), `dfpilot/traps.py` (`draft`), `lua/dfllm/economy.lua` (`M.state`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
`traps@S1` in the draft with no mechanism free; `plan check` advised "add traps at=bridges" for a lane that cannot be built.

## Root cause
(1) BUG-611's `noparts_reason` read `stock.mroute` only; the kernel clears `mroute` when no trap waits for a part (`economy.plan_mech`: short 0), so a fort with `mfree 0` and no route looked fine, and `ordered` / `stone` (an order is open that never gets made) held the gate off while a traps project hung at "waits for trapparts x1". (2) The gate sat behind the draft (`drop_impossible`, run after `propose`), `traps.draft` itself drew the lanes. (3) `traps.gate` (check) advised the lane unconditionally.

## Fix
- State `stock.mtp` (`economy`, from `plan_mech`: the trap parts the planned traps wait for); `noparts_reason`: `mfree` 0 and `mtp` > 0 (traps already hang at "waits for trapparts", whatever the route) gates new lanes, since they would wait behind them. The first traps of a fort with no route yet are still drafted (the kernel then orders the mechanisms).
- `traps.draft`: no lane is drafted while `fort.nostone` or `fort.noparts` holds (note `BUG-628`).
- `plan.check`: the trap-lane warning says "not buildable now: <reason>".

## Tests
`tests/test_bug626_628_f40_plan.py` (3 for BUG-628), `tests/lua/test_bug434_435.lua` (+1: the state carries mfree and mtp)

## Live check
Basementflew: with `stock.mfree 0` and `stock.mtp` > 0 in the state (a traps project at "waits for trapparts"), `plan propose` draws no traps and the notes say why; with parts free (mfree 16 in the save copy used for the offline repro) the lanes are drafted as before.
