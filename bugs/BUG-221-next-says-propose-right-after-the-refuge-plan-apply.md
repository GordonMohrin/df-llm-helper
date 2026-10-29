# BUG-221 NEXT says `plan propose` right after the apply of a plan that builds the refuge
Status: fixed (offline, live-untested)
Severity: medium (a weak model proposes and applies again and again)
Found: 2026-10-29, live round 4, i-test3 "Earthboat" (FRICTION-next-loop)
Module: `dfpilot/guide.py` (`gather`, `_r0`, `decide`)

## Actual
Right after `plan apply` y380 (and after the second apply) `next` printed `NEXT: dfllm plan propose y.json / WHY: R0 refuge/fortcore:
refuge_dry ...; the plan builds these pieces (fortcore stage 3, refuge drink and beds)`, while the applied plan held fortcore stage 3,
refuge_beds and refuge_drink. `_r0` gave PLAN_CMD for any refuge fail; `_plan` is silent for a current-year plan.

## Fix
`gather` sets `refuge_proj` (`_refuge_project`): the ids of this year's applied plan builds and of bp projects with no PROJECT_DONE that fix
a refuge fail (`_refuge_build`: fortcore stage 3 or a new core's stage 1, refuge_beds, refuge_drink, a seal not at=audit), and a running
fortcore `s3.*` row of state.proj. With any, `_r0` waits (no command) and the idle answer says `R0 waits on ... (the applied plan builds it:
<ids>; wait)`. PLAN_CMD only when the plan is from another year or holds no such build (or they are all done).
Review: cancelled projects (bp/.cancelled), fortcore projects a breach stopped (core_breaches) and an older bp file that is only
a fortcore stage 1 (the fort's first core, often stalled for years) do not count, so they cannot keep NEXT waiting for ever.

## Tests
`tests/test_bug220_223_cli.py` (wait with ids, propose when done / another year, the state.proj row, an audit seal is no fix; cancelled and old stage-1 projects do not count), fail on 5e9e719.

## Live check
A fort at R0 with refuge_dry / no_inner: `plan apply` a plan with fortcore stage 3 or refuge_drink, then `python -m dfpilot next`: `NEXT:
nothing`, WHY names `the applied plan builds it: y<Y>s<S>b<I>, ...; wait`, never `dfllm plan propose`.
