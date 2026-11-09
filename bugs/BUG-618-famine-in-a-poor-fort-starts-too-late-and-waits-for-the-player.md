# BUG-618 Famine in a poor fort: the crew starts at 8 food days, the kitchen, butcher and bowyer wait for the player, the caravans are asked at 29 days
Status: fixed (offline, live-untested)
Severity: high (a fort without wood or stone starves in weeks)
Found: 2026-11-09, Run 16b i2 Valleyhame y372-y373 (food 0-4 days three times: `no cook ingredient (135 inedible (CABBAGE:LEAF))`, `hunt: no bolts`, `hunt: no crossbow, no Bowyer's workshop`, famine decision `block [cook, hunt]`, `kitchen` / `butcher` / `bowyer` as the player's commands)
Module: `lua/dfllm/economy.lua` (`fcrew_line`, `fcrew_want`, `fcrew_run`, `food_shops`, `shop_asked`, `plan_gear`, `fd_wants`, `food_early`, `food_block`, `cook_why`), `config/baseline.json`, `dfpilot/fairplay.py`

## Actual
The events of Valleyhame (`events.jsonl` 921-1001): the famine decision at food 0 / 1 / 4 / 8 days listed `no cook ingredient (135 inedible (CABBAGE:LEAF))`, `hunt: no bolts`, auto `trade, crew`; the food crew (`famine crew: food 8 days`) came when the famine started (`famine_days` 10), food was 0 six days later; the caravans were asked at 29 days (`food_low`).

## Root cause
1. The CABBAGE:LEAF items are not a missing path. Vanilla `plant_garden.txt`: CABBAGE's STRUCTURAL material (the cabbage) is EDIBLE_RAW / EDIBLE_COOKED; its LEAF material (the growth `cabbage leaf`) has no edible flag, no ALCOHOL and no MILL reaction (only `LEAF_DYE` powder). A kitchen, still or quern cannot use it; the census (`economy.lua` classify, `food_inedible`) is right and the food is the cabbage the farm plot grows. The text only said `inedible`.
2. `fcrew_run` / `fcrew_want` started the crew at `famine_days` (10): `fam = p.famine ~= nil or food_d < lim`.
3. Kitchen, Butchers and the Bowyer's workshop were only the player's commands in `food_block` (`M.FOOD_CMD.kitchen` / `butcher` / `bowyer`), also in a fort whose decision nobody answers. `plan_gear` named `wood` for the crossbow and bolts without a workshop that makes them and asked for no shop.
4. `fd_wants` asked for food only below `food.pre_days` (30) or in a famine; `st.food.falling` (the farm request's trend) was not used.
5. Hunters wanted with a crossbow in the fort and no bolts, no logs and no bone: nothing brought bolts.

## Fix
- `economy.fcrew_line(c)`: the crew starts below `max(famine_days, famine_crew.pre_days)`; new config `famine_crew.pre_days` (20, 0-400; 0 = the old line), the crew goes back at `off_days` (30) as before.
- `economy.food_shops` (T.watch, before the decisions): below `pre_days` or in a famine the missing Kitchen, and with tame animals standing the Butchers, are asked for (`M.ws_ask` why `mandatory`, `request_days`); `plan_gear`: crossbow or bolts wanted, logs in the fort (`left('wood') > 0`), no shop that makes them -> the Bowyers are in the `gear` request. `food_block` lists a shop that was asked for as `auto` (`Kitchen requested`, `Butcher's shop requested`, `Bowyer's workshop requested`), not as the player's blocker.
- `fd_wants`: food falling over `food.trend_days` and between `pre_days` and twice `pre_days` asks the caravans for 20 food (`economy.food_early`); hunters wanted with a crossbow, no free bolts, no logs, no bone: `bolts` (25).
- `cook_why`: a LEAF / FLOWER / BUD token says `(CABBAGE:LEAF: no food use)` while the text stays under the 120 characters of the stuck-order reasons.
- Already there (not changed): fishing (`fish_want`, `fish_start`, the `Fishery` request), gathering (`gather_low`, BUG-038), butchering (`T.slaughter`: surplus animals marked in food_low / famine, with a Butchers shop), hunters at food_low (`hunt_want`), bolts at a Bowyer / Craftsdwarfs (`gear` `bolts`).

- Behaviour change: once the kernel asked for a shop (`shop_asked`), the `food_low` / `famine` decision lists it under `auto` and no longer as the player's `kitchen` / `butcher` option, and a Butchers request is no new blocker (BUG-008 dedupe: no second decision). Tests test_economy.lua, test_economy_food.lua, test_economy_gather.lua adapted deliberately.
- Honest effect: the Valleyhame leaves would not have been usable even with a fixed cook path; what would have helped is the earlier crew, the shop requests, the trade wants and (with logs) the Bowyers request.

## Tests
`tests/lua/test_economy_fcrew.lua` (crew at 15 food days, not at 25, `pre_days` 0 keeps the old line, back at food), `tests/lua/test_economy_chains.lua` (Bowyers asked with logs, not without, not with a shop), `tests/lua/test_economy_fishing.lua` (Kitchen / Butchers requested and listed as auto, opts without `kitchen`; falling food asks for 20 food, 190 days does not). No test for the bolts want and for the cook text note.

## Live check
A fort with 10-20 food days: `famine crew` line in kern.log before 10 days, `PROJECT_REQUEST workshops ... Kitchen` and the decision's `auto` listing `kitchen`; with logs and a crossbow squad / hunters wanted but no Bowyers: `PROJECT_REQUEST ... why=gear types Bowyers`; the trade wants hold `food` at 30-60 days with falling food.

## Open
Without logs a Bowyer cannot make a crossbow (wood only): a Valleyhame-like fort needs wood or a crossbow by trade first; the request is only made when logs are in the fort. Cabbage heads come from farm plots; gathered leaves feed nobody.
