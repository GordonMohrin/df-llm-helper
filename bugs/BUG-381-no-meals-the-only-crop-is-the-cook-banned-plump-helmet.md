# BUG-381 0 meals: the only crop the farms plant is the plump helmet, which the kitchen may not cook
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16 (i1 Bachwald, i2 Ostgate, i4 Plankscale; `runs/run-16a..d/FR-BUGS.md`), main ec9bd8e
Module: `lua/dfllm/economy.lua`

## Actual
`status` stock line `HUNGRY n ... meals 0 (raw food is not cooked)` for months (i4: 20+ warnings, food 1092-1845 days, 1-3
hungry); the kitchen stood (startup shops), COOK was held, but no `PrepareMeal` ran.

## Root cause
kern.log (i2/i4): `food 1092 days but 2 citizens hungry and no prepared meal ... (0 cook ingredients, 2224 cook-banned: D-09
MUSHROOM_HELMET_PLUMP, kitchen built, COOK labor held)`. The census counts the plump helmets as cook-banned (config `kitchen`,
Gordon's rule D-09: brewed, never cooked), so `cook_n` is 0 and the manager's PrepareMeal order has no ingredient. Nothing was
wrong with the kitchen, the labor or the order; nothing else was farmed: `slot_crop` (`economy.lua`, the kernel is the only
farmer once autofarm is off, `autofarm disabled (1 season slots it emptied or changed again)` in i3/i4) takes the crop
with the most usable seeds, and the embark's plump helmet seeds outnumber every other crop. BUG-345's `cook_repair` lifts
only kitchen exclusions, never D-09 or a farmed crop.

## Fix
`M.cook_plan` (before `M.fiber_plan`): while the kitchen has fewer cook ingredients (`cook_n`) and fewer meals than citizens,
`farms.cook_slots` (default 2, 0 = off; config/baseline.json, fairplay limit 0..50) empty slots of a season take a crop with
usable seeds whose plant is EDIBLE_COOKED (structural or a growth) and not on the config's Cook ban (`M.cook_plant`);
`M.slot_crop` takes that pass first, `farm_fills` counts the slots a season already holds of such a crop (planted slots are
never replaced), `T.slotnow` and `T.farmslots` pass the plan. One kern.log line when the crop set changes; with no seed of a
cook crop in stock the line says so and `M.fd_wants` asks the caravans for seeds. D-09 is untouched: plump helmets stay brewed.

## Open
A fort with no seed of any cook crop waits for the caravan; wild cook plants are not gathered for seeds.

## Tests
tests/lua/test_bug381_cook_crop.lua (2 cases; fail on ec9bd8e: every slot plump helmets).

## Live check
i4-like: `autofarm disabled ...` then `kitchen has 0 cook ingredients and 0 meals for N citizens: the farms plant a cook crop
(BUSH_QUARRY...)`; a plot shows the cook crop in 2 slots of a season, plump helmets in the rest; after the harvest cook_in > 0,
PrepareMeal runs, `meals` > 0, HUNGRY clears.
