# BUG-321 plan check's refuge bed ERROR without a site blocks the year plan; refuge_dry asks for a store already planned
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15b (Earthboat) and Run 15c (Inkintense), live, round 3
Module: `dfpilot/plan.py` (_bed_site, refuge_gate), `lua/dfllm/readiness.lua` (refuge_dry text)

## Actual
Earthboat y385 spr d29 (P5): `plan propose` -> `ERROR refuge: Tiefe+ has 16 beds < 21; ... add refuge_beds n=3`; no site took it (BUG-319),
also not at phase_target P4, so `plan apply` said `not applied` and plan y384 stayed active (goal G2 red for y385). Inkintense y377:
SIEGE_UNREADY / R0 said `Tiefe+ has no drink (drink 21<50, its 1 well is dry ...): plan its drink store (bp sites refuge_drink)`
while plan y377 held refuge_drink y377s0b2 (queued after the beds, runner plan_loads).

Root cause: `dfpilot/plan.py:941` (refuge_gate): at P3+ a bed shortage without a site (`fort.refuge.bed_site` False) and without
fortcore stage 3 fell through to `need()`, an ERROR, although no build of the plan could give the beds; BUG-222 only covered the case
with stage 3 under way. `plan.py:711` (_bed_site) asked `rank_sites`, so ranked sites all held by placed projects counted as a site (the
draft then failed check's `only 0 free site(s)`). `lua/dfllm/readiness.lua:436` named no store project under way.

## Fix
refuge_gate: no free bed site and nothing in the plan -> a warning `refuge: Tiefe+ has 16 beds < 21 (+2 under way); no free site takes
refuge_beds now: the plan may be applied; next: dfllm bp sites refuge_beds --fresh once the refuge rooms under way are dug (new ones dig
off them, BUG-319), or bp.place refuge_beds at an anchor A<x>_<y>_<z>`. A free site keeps the ERROR that asks for the build. _bed_site
uses `free_sites(.., n=1)` (what bp.place S1 resolves). readiness: with no standing store, `runner.pending('refuge_drink')` > 0 ->
`its drink store is under way (N project(s))` instead of `plan its drink store`.

## Tests
`tests/test_bug321_refuge_bed_gate.py` (2, fail on 1d17c7e): P5 plan with 16 < 21 beds and no site -> no ERROR, the warning with the
next step; with a site the ERROR stays; _bed_site False when every ranked site is taken. `tests/test_bug220_223_cli.py`: the BUG-222 case
'no stage 3 anywhere' is now this warning. `tests/lua/test_readiness.lua` (BUG-321 test, fails on 1d17c7e): the drink text names the
store under way.

## Live check
Earthboat: `dfllm plan propose y385.json` / `plan check` show the bed line as a warning; `plan apply` applies y385. With BUG-319 the bed
site exists, then propose drafts refuge_beds again (ERROR only if it is left out). Inkintense: once y377s0b2 is queued SIEGE_UNREADY says
`its drink store is under way (1 project)`.
