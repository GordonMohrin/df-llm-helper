# BUG-403 plan propose drafts fortcore stage 3 before stage 2
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16a (i1 Bachwald y372, `runs/run-16a/FR-BUGS.md` 'plan propose zeichnet fortcore st3 vor st2'), main 503bb8b
Module: `dfpilot/plan.py`

## Actual
Draft P5: `seasons[2]` fortcore stage 3, `seasons[3]` stage 2 -> `plan check` ERROR BUG-164. The player moved both by hand.

## Root cause
`propose` appends the builds to the seasons in list order (the season loop in `plan.py`) after several steps that reorder or insert them:
`core_gaps` (inserts missing stages 2..k-1), `defense_order` (BUG-377, defence builds ahead of growth), the surface-core swap
(BUG-387) (`core_gaps` inserts a stage only among the builds drafted now). Nothing checked the final order, `core_order_gate` only reported it.

## Fix
`plan.core_stage_order(builds, seasons)`: after the seasons are filled, the slots held by the non-retrofit fortcore builds this draft added (builds kept from the
same year's earlier plan stay put, applied ones keep their ids) are refilled in ascending stage order; the seals, refuge pieces and defence builds keep their places.

## Open
A stage 3 kept from an earlier plan of the same year with a new stage 2 appended behind it is not reordered (kept builds may be applied).

## Tests
tests/test_bug403_405_plan_order_guard.py (slot sort across seasons, retrofit and kept builds untouched, propose).
