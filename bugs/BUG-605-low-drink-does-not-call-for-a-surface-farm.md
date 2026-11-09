# BUG-605 Drink 0 days with food 331 days: no farm plot is ever tried on the surface, so nothing can be brewed
Status: fixed (offline, live-untested)
Severity: high (no brewing for four years, the dwarves drink from the outside pond; AUTO_FAIL every minute)
Found: 2026-11-09, Run 16c i3 Wallfree y373-y377 (`farms: site S1: only 0 free site(s) for farms plots=1 ... no soil level in the fort (soil on its dug floor: z146 0/357)`; stock `drink_d 0`, `dwhy: no brewable plants (56 seeds fit no farm plot: underground seeds; a plot is required)`, `food_d 331`; grass on the embark)
Module: `dfpilot/plan.py` (`farm_low`, `farm_facts`, `food_draft`), `dfpilot/wake.py` (`food_urgent`)

## Actual
The room farm has no site in a fort whose dug floor is stone. follow's surface try (`wake.farm_tries`, BUG-340) and the plan's farm draft (BUG-297 `food_draft`, BUG-460) run only when the FOOD is low: `food_urgent` was `food_d < FOOD_DRAFT_D` (60), otherwise the surface plots need `plan.surface_core` (BUG-413, default off). Food was 143-331 days, so the surface farm was never tried, only the room farm failed again every minute with an advice to use p.surface=1; the drink stayed at 0 days (the still has nothing to brew without a plot).

## Root cause
`dfpilot/wake.py` `food_urgent` (the `urgent` flag of `farm_tries` / `farm_site`) and `dfpilot/plan.py` `farm_facts` / `food_draft` looked at `stock.food_d` only; `stock.drink_d` with no brewable plants was no reason for a farm.

## Fix
`plan.farm_low(state)`: ('food', days) below `FOOD_DRAFT_D` 60, else ('drink', days) below `DRINK_DRAFT_D` 30, else None. `wake.food_urgent`, `plan.farm_facts` and `plan.food_draft` use it: low drink tries the surface farm on soil or grass (`bp/sites.py` `_surface_farms`: inside the walls, near the entrance, else the nearest soil on the citizens' walk group) in PEACE although `plan.surface_core` is off, exactly as low food does (the surface fort stays off); the draft note says `drink (no farm plot, nothing to brew) 0 d (< 30)`. No change to `cmd.place` (a first attempt to fall back there would have bypassed the PEACE and surface_core guards and was dropped).

## Tests
`tests/test_bug602_606_f39.py` (3: `farm_low`, `food_urgent`, `farm_tries` in PEACE and in a siege; `food_draft` for drink; `farm_facts` finds the surface site for low drink on a snapshot with soil)

## Live check
On a fort with food > 60 d, drink 0 d and no plot: within a minute follow logs `BUG-340: no farms site for {plots: 2}: placed with {plots: 2, surface: 1}` (cli.log `auto:farms`) or, with no soil / grass site, the `farm_ground_why` reason; `plan propose` drafts `farms@S1 p.surface=1` with the drink note.
