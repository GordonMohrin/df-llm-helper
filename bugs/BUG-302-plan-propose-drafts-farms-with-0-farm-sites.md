# BUG-302 plan propose drafts farms@S1 when no farm site exists
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15 round 2/3 (Drillchamber; runs/run-15d-drillchamber/FR-BUGS.md 'Runde 2', 'Runde 3')
Module: `dfpilot/plan.py` (propose, farm_facts, emergency_drafts)

## Actual
Drillchamber y376-y378: `plan propose` drafted `farms@S1` each time ("propose schlägt farms trotz bekannter 0 Sites wieder
vor"); `plan check` then refused it (`only 0 free site(s) for farms`), the session removed it by hand. Reproduced on a copy
of the y378 runtime: the draft holds `('farms', 'S1')` while `farm_facts` says site `none`. Root cause: two drafts ignore
the fort's farm site: the phase loop drafts every `proj` deliverable of P0 (plan.py:2233, farms included) and
`emergency_drafts` adds farms whenever food or drink is low (plan.py:2405); the site fact (`farm_facts`, BUG-297, looked up
below 60 food days, plan.py:234) was used only by `food_draft`.

## Fix
`farm_facts` keeps its 60-food-day gate (the site ranking renders the template; plan apply must not, tests/test_cli_plan.py)
with its lookup moved to `plan.farm_site` (room, surface, none, None = no snapshot); `farm_site_fix` runs over the phase and emergency builds before they are ordered: site `none` leaves every farms build
out (note `BUG-302: farms left out: no farm site (bp sites farms: 0 room, 0 surface sites); the P0 deliverable is waived
(phase.waive farms, follow sends it); food: trade.want food, seeds; fishing; butcher.mark`), site `surface` gives them
`p.surface=1` in PEACE (left out with a note in any other mode), room or unknown keeps them. Above 60 food days the site is not looked up: a phase farms build stays,
and follow waives the deliverable once a placement finds 0 sites (BUG-300).

## Tests
`tests/test_bug300_302_phase.py` (farm_site_fix, propose with site none / room). Fail on 9ef2ccb.

## Live check
Drillchamber `dfllm plan propose y.json`: no farms build, the note `BUG-302: farms left out: no farm site`; `plan check`
has no `only 0 free site(s) for farms` ERROR.
