# BUG-413 the surface core and the surface room variants are drafted by default
Status: fixed (offline, live-untested)
Severity: high (Gordon does not want a surface fort; round 21 made it the default for every aquifer world)
Found: 2026-11-04, Gordon's decision: "oberflaechenfort finde ich doof"; main 503bb8b
Module: `dfpilot/plan.py` (surface_core_on, surface_need, farm kinds, office/hospital surface), `dfpilot/wake.py`, `dfpilot/fairplay.py`, `config/baseline.json`

## Actual
Round 21 (BUG-387/389/396/384/297/302) drafted `surfacecore` in place of the fortcore whenever none could be dug, and the surface
variants of office, dining, bedrooms, tavern, hospital and farms wherever no dug Z4 floor existed.

## Fix
- Config switch `config/baseline.json` `plan.surface_core` (default false; `fairplay.PLAN_LIM` bool, `lint --config` refuses another
  type; `plan.surface_core_on()`; a bad value keeps false). With it off:
  - `plan.surface_need(sf)` is false: `propose` drafts no `surfacecore`, no `surface_core_swap` (its dining/bedrooms/tavern/office/
    hospital `p.surface=1`), `stage3_gate` and `core_order_note` treat the fort as a dug one;
  - `surface_facts` computes `aq` (BUG-412) instead of the surface compound's site;
  - `office_facts`/`office_surface_due`, `hospital_facts`/`hospital_surface_due` and `farm_site`/`farm_site_plots` (`_farm_kinds`)
    offer no surface site; `wake.farm_tries` has no surface try, and the PROJECT_REQUEST office waits for a dug core (no
    `office surface=1`).
  - Not touched: the startup workshops beside the wagon (`workshops surface=1`, BUG-356, also the mood shops' second try, BUG-394) and
    the trade depot (BUG-368): temporary/normal, not a surface fort. Placing a `surfacecore` by hand (`bp.place`) still works.
- With the switch on the old behaviour is unchanged (the round 21 tests run with it on).

## Tests
`tests/test_bug412_413_aquifer_default.py` (no surfacecore and no `p.surface` room in a default draft even when the core cannot be
dug; startup workshops stay; the switch brings the surface core back; bad value keeps the default; the shipped baseline has it false and
lint passes; hospital/office/farm surface variants off by default). `test_bug387_389_surface_core.py`, `test_bug384_surface_hospital.py`,
`test_bug396_399_supply.py` run with the switch on.

## Open
Farms: with the switch off a fort without a farms room site (no dug core) drafts no surface farm; food then waits for the core. The
phase deliverable `farms` is waived (`bp sites farms`: 0 sites) as before.

## Live check
`dfllm plan propose` in a fort whose core cannot be dug: no `surfacecore`, no `surface=1` rooms (workshops surface=1 for the startup
set and the depot are still there); `config/baseline.json` `"plan": {"surface_core": true}` brings round 21's draft back.
