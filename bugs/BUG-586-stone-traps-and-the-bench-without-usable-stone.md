# BUG-586 `traps@S1` proposed every year without stone and stalled 300+ days
Status: fixed (offline, live-untested)
Severity: medium (a project that can never finish; the year plan is clogged)
Found: 2026-11-09, Run 16a i1 Basementflew (traps@S1 every year, 300+ days), Run 16d i4 Trumpetrealms (DF cancels 'Needs non-economic hard stone')
Module: `dfpilot/plan.py` (`NEEDS_STONE`, `nostone_reason`), `lua/dfllm/economy.lua` (state `stock.rhard`), `dfpilot/schema.py`

## Actual
`plan propose` drafted `traps` every year; every trap needs a mechanism; with no usable stone none was ever made.

## Root cause
BUG-500 left traps out of NEEDS_STONE, and `nostone_reason` knew only the soil mark and `rock 0` + MATERIAL_SHORT, not DF's refusal of the rock jobs (BUG-545) in a fort that has boulders of mudstone.

## Fix
`traps` joins `NEEDS_STONE` (left out of the draft with a note, a `plan check` warning for a new one); new state flag `stock.rhard` = `economy.hard_denied` (DF cancelled the rock jobs); `nostone_reason` returns a reason for it, so the BUG-581 bench=0 and this rule also hold in a mudstone fort.

## Tests
`tests/test_bug581_585_f37_econ.py` (`test_no_traps_while_stone_is_out_of_reach...`, state key)

## Live check
`plan propose` in a fort whose kernel logs the BUG-545 `no_hard_stone` question: no `traps` build, the note names why.
