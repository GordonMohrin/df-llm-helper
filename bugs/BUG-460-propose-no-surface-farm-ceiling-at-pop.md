# BUG-460 `plan propose` drafted no surface farm, and set pop_ceiling to the citizens now without saying why
Status: fixed (offline, live-untested)
Severity: high (food 1 day; the player placed the farm by hand after drink fell 85 -> 19 days)
Found: 2026-11-05, Run 16d i4 Orbblock y374 winter (`runs/run-16d/FR-BUGS.md` "plan propose setzt pop_ceiling auf aktuelle Pop (26) statt 100"; "Hungersnot ... 1 Oberflaechenfarm")
Module: `dfpilot/plan.py` (`_farm_kinds`, `farm_site_plots`, `farm_site`, `farm_plots_for`, `food_draft`, `farm_site_fix`, `ceiling_held_note`, `_summary`), `dfpilot/wake.py` (`farm_tries`, `food_urgent`)

## Actual
`fort.farms.site` was `none` (underground farms: 0 sites) although `bp sites farms surface=1` found one; the draft carried no farm ("no farm site"). `plan propose` (pop 26) wrote `policy.pop_ceiling 26` where the goal is 100, and the summary line said only `ceiling 26`.

## Root causes
1. `plan._farm_kinds` (BUG-413) looked up the surface plots only with `plan.surface_core` on, so in a famine of a fort with no dug farm room the site search never asked the surface; follow's `farm_tries` did the same (no surface try), and `_waive_farms` waived the phase's farms as "no site".
2. `food_draft` drew the surface farm with the template's two plots whatever the population.
3. `propose` holds `pop_ceiling` at the citizens now while the defence is short (BUG-377: refuge_dry, traps 0, armor); the reason went to the end of the notes and the summary line printed the bare number.

## Fix
- `_farm_kinds(urgent)`: with food below `FOOD_DRAFT_D` (60) the surface plots are looked up too (`farm_facts` passes it); the surface fort stays off (no surface core, no surface rooms). `farm_tries(params, mode, urgent)` and `Follower._place_farms` / `_waive_farms` use `wake.food_urgent(state)`.
- `food_draft` / `farm_site_fix` draw the surface farm with `plots = ceil(citizens / 10)` (1-4, `FARM_POP_PER_PLOT`), never more than the soil has room for (`fort.farms.plots`); `cmd.place` still falls back to fewer plots itself (BUG-316).
- `ceiling_held_note`: a ceiling under the policy's cap says `pop_ceiling 26 held (policy 100): defence short (traps 0, ...), BUG-377` right after the phases in the notes, and `_summary` prints `ceiling 26 (held, policy 100: defence short (traps 0))`. The ceiling itself stays the BUG-377 hold when a named gap holds it; with no gap it is the policy's.

## Tests
`tests/test_bug458_461_f28d.py` (kinds with `urgent`, `farm_tries` urgent, `food_urgent`, plots per citizens, `food_draft`, `farm_site_fix`, the held note and the summary).

## Live check
`dfllm plan propose` at food < 60 days in a fort with no farms room site: `farms@S1 p.surface=1 p.plots=N` is in the draft; with a defence gap the summary reads `ceiling N (held, policy 100: ...)`.
