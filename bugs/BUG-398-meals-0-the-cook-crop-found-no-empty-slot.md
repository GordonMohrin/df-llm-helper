# BUG-398 meals 0 'raw food is not cooked' after the cook-crop fix: every farm slot was planted already
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16b (i2 Ostgate R2, Pop 79, food 712 d, `runs/run-16b/FR-BUGS.md`), main bb87afb
Module: `lua/dfllm/economy.lua`

## Actual
i2 kern.log: 40+ lines `food 6xx days but N citizens hungry and no prepared meal: raw plants and seeds are not cooked (0 cook
ingredients, 2xxx cook-banned: D-09 MUSHROOM_HELMET_PLUMP, kitchen built, COOK labor held)`; the first run of the R20 code (after
`economy boosted: first run since the boot`) logs `kitchen has 0 cook ingredients and 0 meals for 80 citizens: the farms plant a cook
crop (BERRIES_PRICKLE,TURNIP; at most 2 slots a season)`; the Kitchen had toppled meanwhile (`BUILDING_TOPPLED` after the broker's
tantrum).

## Root cause
BUG-381's `M.cook_plan` gives `farm_fills` only EMPTY slots (`economy.lua` `farm_fills`; its test even asserted "a planted slot is never
replaced"). i2's 175 farm tiles had been planted with plump helmets from the first day (autofarm off, `slot_crop` = the crop with the
most seeds), every slot of every season was taken, so the plan found no slot and `cook_n` stayed 0. Two slots a season for 80 citizens
were also too few.

## Fix
- `farm_fills`: a planted slot (not wrong, not seedless) of a plant the kitchen will not cook (`not M.cook_plant`: plump helmets and
  brew-only crops) is swapped for the cook crop while the plan has slots left for that season (`M.cook_pick`, shared with
  `slot_crop`); planted cook slots count against the plan, so it is idempotent. The plan carries `nocook`.
- `M.cook_plan`: `max` = `farms.cook_slots` + 1 per 30 citizens (at most 8).

## Open
The Kitchen itself: a toppled one is asked for again as `workshops` (PROJECT_REQUEST missing) but a fort without a core or startup block
may not get one (i2: the old `workshops` project 'set aside 4853 days'). A fort with no seed of any cook crop still waits for the
caravan (BUG-381).

## Tests
tests/lua/test_bug381_cook_crop.lua (+2: swap up to the cap, idempotent, kept with meals or without cook seeds).

## Live check
i2-like: all plots plump helmets, `kitchen has 0 cook ingredients ... the farms plant a cook crop`; within the cap, slots of every
season change to the cook crop, after the harvest `cook_in` > 0, PrepareMeal runs, `meals` > 0, HUNGRY clears.
