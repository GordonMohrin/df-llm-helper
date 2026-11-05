# BUG-430 with 0 boulders and 0 logs the year plan drafts no stone dig and no wood or block request
Status: fixed (offline, live-untested); open: a soil fort has no stone to quarry at all (trade is then the only source)
Severity: high (61 construction pieces suspended for 200-1200 days, 17 of 18 thirsty with no cistern or well material)
Found: 2026-11-05, Run 16b i2 Glendagger y372-y378 (`runs/run-16b/FR-BUGS.md`), main 9e756ea
Module: `dfpilot/plan.py` (`stone_digs`, `dead_dig`, `material_famine`, `propose`, `fit_stone_dig`, `quarry_fallback`, `fit_explore`)

## Actual
MATERIAL_SHORT "no rock, no logs" (boulders 0, logs 0), JOBS_SUSPENDED 51-61 "buildingplan: waiting for materials", projects "set aside 200-1300 d". `plan propose`
only warned (`rock: ... add bedrooms n=4`); the player placed the stone dig by hand.

## Root cause
1. `plan.py stone_digs` (-> `fort.stone_dig`, which switches `propose`'s `stone = rock_goal(s)` off and the check's warning): any bp file of a STONE_DIGS template
   without PROJECT_DONE counted as "a stone dig under way", also an explore parked at `breach:heavy_aquifer` and a bedrooms project set aside "stalled" at its build stage.
2. A stone dig that was drafted is cut by `fit_stone_dig` when no bedrooms site ranks (rooms hang on the dug Z4 floor of a fortcore): the notes then say "a stockroom or
   explore dig" and nothing is drafted in its place.
3. Wood was never asked for: nothing put `wood` / `block` into `trade.want` for a fort with 0 logs.

## Fix
- `stone_digs(save_dir, state)`: with the state, a project row that is `dead_dig` (parked, breach, set aside, stalled, blocked, paused, or past its digging: label `build`)
  does not count.
- `material_famine(save_dir, s)`: the newest MATERIAL_SHORT of the last 60 game days: `{short, rock0 (stock.rock 0), logs0}` -> `fort.famine`.
- `propose`: in a famine `rock0` drafts the stone dig even without `rock_need`; `trade.want` gets `wood` (logs0) and `block` (rock0) first; the notes say BUG-430.
- `fit_stone_dig` -> `quarry_fallback`: a left-out stone dig in a rock famine is replaced by `explore@S1 p.avoid=<every known aquifer / wet level, e.g. 123-129>` in the
  same season (`fit_explore` passes `p.avoid` to the ranking and fits the depth: rock or unknown around the shaft, public Z4 floor, no revealed water / cavern / damp mark,
  not near a recorded breach, never above the refuge level). No safe site: the note says trade stone / block / wood.

## Tests
`tests/test_bug429_431_aqprop.py` (dead digs, famine from events, draft with trade.want, quarry with avoid and depth fit, no famine no quarry).

## Live check
Rock 0 + logs 0 (MATERIAL_SHORT): `plan propose` lists `wood, block` first in trade.want and a stone dig (bedrooms, else explore with `avoid`); a parked explore no longer
hides the need.
