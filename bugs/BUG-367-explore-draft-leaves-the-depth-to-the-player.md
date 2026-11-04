# BUG-367 explore depth: the draft leaves p.depth to the player
Status: fixed (offline, live-untested)
Severity: medium (explore parked or refused, the ore search stops)
Found: 2026-11-04, Run 16b i2 (y378; `runs/run-16b/FR-BUGS.md`), main 2fcd6e0
Module: `dfpilot/plan.py` (auto_plan)

## Actual
The draft asked for an explore of depth 12 although an aquifer layer lay on z126; the answer named `p.depth=2` ("depth 2 would
be accepted at ...") for the player to type. On i2's data only depth 2 has a site (12, 9, 6, 4 all 'reaches an avoided level').

## Root cause
`plan propose` (CLI) runs `fit_explore`, which picks the deepest of EXPLORE_DEPTHS with a site; the automatic plan of `follow`
(`plan.auto_plan`) and a hand-edited draft did not: its explore stayed at the template default 12 and `place()` refused it
with the depth hint only.

## Fix
- plan.py `auto_plan` runs `fit_explore` on its draft and on the raise candidate (as `propose` does).
- Not changed: `bp.place explore` without a depth stays refused with the depth hint (test_c2_reclaim, BUG-067): an explicit
  placement is the player's choice; the draft is where the depth is chosen.

## Tests
tests/test_bug364_367_aquifer_core.py (`test_the_automatic_plan_fits_the_explore_depth_too`).

## Open
The cause is inferred from the code paths and i2's data (only depth 2 has a site there, `fit_explore` finds it, auto_plan never
called it); the exact draft the player saw at y378 is not on file. A build that sits in the applied plan of the same year keeps its
depth (append-only plan), `fit_explore_kept` names cavern cases only.

## Live check
i2-like (aquifer layer under the surface): `plan propose` and follow's plan draft explore with `p.depth=2` without typing it;
`plan propose` names `explore: depth 2 at [...]`.
