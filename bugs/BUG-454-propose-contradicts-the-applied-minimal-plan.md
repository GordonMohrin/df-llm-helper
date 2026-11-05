# BUG-454 A draft written before follow's MINIMAL plan checks with ERRORs 'applied as ...; keep it'
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-05, Run 16a i1 Syrupobeyed y384 spring (`runs/run-16a/FR-BUGS.md` "OBS Runde 5 Start")
Module: `dfpilot/plan.py` (`rebase_on_applied`, `run`)

## Actual
follow applied a MINIMAL plan for y384 (explore x4, bedrooms) before the player's `plan propose`; `plan check` of the player's draft gave 3 ERRORs "seasons[0].build[1]: ... is applied as y384s0b1; keep it". The draft had to be rebuilt by hand.

## Root cause
`stable_ids` demands every applied build of the same year at its index. `propose` builds on `applied_plan` (same year), but a draft file written earlier (or by a propose that ran before follow's apply) lacks the applied builds, and `check`/`apply` took the file as it was.

## Fix
`plan.rebase_on_applied(doc, prev)`: for a draft of the applied plan's year that `stable_ids` would reject, the applied builds stand at their ids (multiset match) and the draft's other builds follow them in their seasons; `plan check` / `plan apply` write the rebuilt draft back and print `BUG-454: ... rebuilt on it`. `plan propose` prints that it builds on the applied plan (follow's MINIMAL plan named).

## Tests
`tests/test_bug450_456_ops.py` (rebase, repeated builds, other year untouched, `plan check` rewrites the file).

## Live check
Write a draft, let follow apply the minimal plan, `plan check draft.json`: the line "BUG-454: the draft did not match the plan applied for y..." and OK.
