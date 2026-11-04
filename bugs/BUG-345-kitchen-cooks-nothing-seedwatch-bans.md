# BUG-345 kitchen cooks nothing: meals 0 with food for 100-700 days, items 'cook-banned'
Status: partly fixed (offline, live-untested): the kitchen exclusions of food are lifted when the kitchen has nothing else to cook (never D-09, never a farmed crop), the texts name the banned material, D-09 `yes` lifts the plump helmet ban in a famine, the seedwatch task runs right after its enable; open: i2's hungry citizens were stranded and patients (no kitchen cause), i1 had no cookable food at all (tree leaves, BUG-340)
Severity: high
Found: 2026-11-04, Run 15 (i2 Guildcleans y386 Runde 2, i1 Inkintense y383)
Module: `lua/dfllm/baseline.lua` (plan: `cp:seedwatch` early in the control-panel list, the `seedwatch` task far behind it),
`lua/dfllm/economy.lua` (cook_banned/census, cook_why, hungry_warn, kitchen), `lua/dfllm/act.lua` (new `kitchen_include`)

## Actual
- i2 Guildcleans y386: `orders` PrepareMeal `no cook ingredient (5 inedible, 15 cut off, 517 cook-banned)`, kern.log economy
  `raw plants and seeds are not cooked (0 cook ingredients, kitchen built, COOK labor held)`, 0 meals beside 100+ food days.
  No dfpilot verb for kitchen bans.
- i1 Inkintense y383: PrepareMeal `no cook ingredient (493 inedible (GINKGO:LEAF), 1 forbidden, 1 cook-banned)`, `raw food is
  not cooked` in the brief.

## Evidence
- i2 events.jsonl ORDER_STUCK PrepareMeal: `1014 cook-banned` (#5131), `966` (#5335), `909` (#5550), `416` (#6551), `309`
  (#6724): the banned stock is eaten raw or brewed, nothing is ever cooked; kern.log 929-1524 `0 cook ingredients` throughout.
- i2 commands.log: `control-panel enable seedwatch` at tick 150019880 (line 38), `seedwatch clear` only at 150049832 (line 121),
  30,000 ticks later; i1 the same (150015609 -> 150057821); later enables (151477421 -> 151493692 clear) too. seedwatch watches
  every plant type at 30 seeds when enabled (hack/docs/docs/tools/seedwatch.txt; baseline.lua:266) and bans the cooking of each
  one below its target (Kitchen::denyPlantSeedCookery: the PLANT and its SEEDS); `seedwatch clear` / target 0 removes the
  type from the watch list and lifts no ban, so every plant short of 30 seeds in that window stays on the kitchen's Cook ban.
- The config ban (D-09, plump helmets: economy `kitchen`) counts among the cook-banned too; economy.lua `kitchen` never took
  it off for D-09 `yes`, it only stopped adding it (a ban set before the famine stood all famine long).
- i2's hungry/starving citizens: STRANDED #8812/#8820 `4 citizens on walk group 12 without food (hunger 90416): no rescue`,
  siege `1 citizen thirsty or hungry in Pflege+`, 19 dehydrated and 7 starved deaths (patients): access, not the kitchen.
- i1: 493 GINKGO:LEAF are no food (inedible); 1 cook-banned: nothing to cook in any case.

## Cause
1. baseline.lua M.plan: `cp:seedwatch` sits in the control-panel loop, the `seedwatch` task (clear + crops at 12) dozens of
   tasks later (per_slice 4 a frame, the game running), so seedwatch's default watch-all-at-30 ran for thousands of ticks.
2. Nothing ever lifted a Cook exclusion of a plant (economy.food_unban only `ban-cooking fruit --unban` for growths in
   food_low/famine), so the kitchen stayed without ingredients while the census counted the food days.
3. economy.lua cook_why / hungry_warn named only the count (`517 cook-banned`), never the material or whose ban it was.

## Fix
- baseline: the `seedwatch` task follows `cp:seedwatch` at once (same slice where per_slice allows).
- economy.cook_banned returns the exclusion's row (cat, subtype, material, token, count) for a kitchen exclusion, `true` for
  the config ban; the census counts `cook_ban_x` (on exclusions) and tallies the banned materials (`st.cban`).
- `M.cook_repair` (T.watch, daily): when the kitchen has no cook ingredient (`cook_in` 0) and food lies on kitchen exclusions,
  `act.kitchen_include` lifts them (at most 16 a day, each once a year; never the config ban, never a farmed crop from
  baseline.status, never a SEEDS exclusion), kern.log `kitchen: nothing to cook, N food items on kitchen exclusions ...:
  cooking allowed again for BERRY_PRICKLE x40, ...`.
- `kitchen`: D-09 `yes` in a famine takes the config exclusion off (`famine (food N days), D-09 yes: ... may be cooked until the
  famine ends`), the next run after the famine puts it back.
- ORDER_STUCK / hungry warn name the first banned material: `11 cook-banned (D-09 MUSHROOM_HELMET_PLUMP)`.
- Contract: act `kitchen_include(item_type, subtype, mat_type, mat_index, what)` -> `ok, 'removed'|'absent'` (economy;
  CONTRACTS.md §act, contract.lua, schema.py, appendix).

## Tests
- tests/lua/test_bug345_kitchen.lua (4; 3 fail on 14ff5a3): a wild plant's leftover ban lifted, the farmed crop and D-09 kept,
  once a year; nothing lifted while something else is cookable; ORDER_STUCK names `D-09 MUSHROOM_HELMET_PLUMP`; D-09 yes
  lifts in a famine and the ban returns after it.
- tests/lua/test_kern_act.lua (+3 checks: removed, absent, bad what), test_economy_fishing.lua (text).

## Live check
- kern.log `kitchen: nothing to cook, ... cooking allowed again for ...` once, then PrepareMeal jobs run and `meals` > 0 in
  status; ORDER_STUCK PrepareMeal `... cook-banned (<material>)`. commands.log: `seedwatch clear` right after `control-panel
  enable seedwatch` on the next load.
- Check in DF's kitchen screen that the lifted plants show "cook" allowed and that seedwatch does not ban them again within a
  cycle (it should not: they are no longer watched).

## Open
- Not checked live that `seedwatch clear` leaves the bans (DFHack source not at hand); the repair does not depend on it.
- The hungry citizens with raw food in stock (i2): stranded on walk group 12 and patients; the `raw food is not cooked` brief
  text still blames the kitchen there.
- i1: tree leaves are no food; with nothing cookable the repair has nothing to lift (BUG-340 open).
