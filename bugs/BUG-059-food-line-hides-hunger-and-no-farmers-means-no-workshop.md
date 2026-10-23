# BUG-059 "food 41 d" while 12 dwarves starve (meals 0); ORDER_STUCK "no Farmers" means no Farmer's Workshop
Status: fixed in eb4d838 (offline, live-untested): the stock line starts with `HUNGRY n` and says `(raw food is not cooked)` at
meals 0, kern.log warns once a week when citizens are hungry and no meal stands above the pre-alarm line, the food_low decision
names it first; ORDER_STUCK names the workshop as one (`no Farmer's Workshop`), carries `kind` (workshop | worker | input), and
the state/status count the stuck orders that miss a workshop (named) apart from the ones that miss a worker
Severity: high (wrong report: it sent the game session into the work details for hours; 12 starved under "food 41 d")
Found: 2026-10-20 .. 2026-10-22, Run 12 y503 autumn d51 and Run 14 y577; notes 37 and 62 of `bugs/RUN11-offene-bugs-und-FR.md`
Module: `lua/dfllm/economy.lua` (M.order_reasons, T.ocheck, M.state, M.food_block, M.food_q, M.hungry_warn),
`dfpilot/brief.py` (line_supply), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual (live, from the notes)
- Run 12 y503: `food 41 d`, `meals 0`, 565 PlantSeeds/GatherPlants unclaimed; 12 dwarves starved in one season, 17 corpses,
  stress 81 %, pop 55 -> 43. The status showed `starving 555` only at the end of the line (labormanager's counter).
- Run 14 y577: ORDER_STUCK `no Farmers` for ProcessPlants; the session debugged the labor and the work detail for several
  rounds. Direct Lua: 0 Farmer's Workshops in the fort, 55 of 55 citizens held PROCESS_PLANT.

## Cause (proved from the code at f17e2b3)
1. **The food days count raw food.** The census counts every EDIBLE_RAW item as food (economy.lua census, the `a.food` branch:
   plants, growths, meals alike); `meals` in the state is the number of *kinds* of prepared meals (`meal_kinds`, 6627).
   A fort with 41 days of raw plants nobody can cook (no kitchen ingredient store, no cook) reads 41 days and `meals 0`.
   The status printed both numbers side by side without a connection (brief.py `line_supply`), and no code counted the
   hungry citizens except the supply alarm (`needs`, 2591), which needs `alarm.units` of them, only brakes the tempo and is
   not part of the food line.
2. **The workshop reason is a bare key.** `M.order_reasons` (3882) wrote `'no ' .. ws[1]:match(':(.+)$')`: `workshop:Farmers`
   became `no Farmers`, read as "no farmer". `OL.WS` demands a built `workshop:Farmers` for ProcessPlants (orderlib.lua).
   Nothing told a missing workshop from a missing worker (`no worker X`, also in `why`) apart in the state or the status.

## Fix
- `st.hungry_n` (daily, `hungry_ids`, DF's "hungry" line `starve.hunger` 50000): state `stock.hungry`; the status stock line
  `stock HUNGRY 12 drink 300d food 41d! meals 0 (raw food is not cooked)`; kern.log `food 41 days but 12 citizens hungry and no
  prepared meal: raw plants and seeds are not cooked (N cook ingredients, kitchen built|missing, COOK labor held|on nobody)`
  above the pre-alarm line, again after 7 days or when the count doubled; below it `food_low` / `famine` put the blocker
  `hungry` (`12 hungry, 0 meals: raw food is not cooked`) first and `food N d (cit, 12 hungry, 0 meals)` in `q`.
- `M.ws_label`: `no Farmer's Workshop`, `no Masons workshop`, `no Smelter furnace`; `order_reasons` returns the kinds; ORDER_STUCK
  `d.kind` (`workshop`, `worker`, `input`), `inspect orders` rows carry it; state `orders.stuck_ws` (+ `orders.ws`, the three most
  missed workshops with counts, <= 60 bytes) and `orders.stuck_lab`; the status line `orders 40 stuck 6 (workshop missing 4:
  Farmer's Workshop x4; no worker 2)`.

## Tests
`tests/lua/test_economy_food.lua` (hungry + meals 0 at 41 days: state, one warning, the decision's first blocker),
`tests/lua/test_economy_orders.lua` (a missing Farmer's Workshop vs. a missing worker: why, kind, state), `tests/test_bug057_059.py`
(status lines, worst case within STATUS_TOKENS, schema); each new test fails on f17e2b3.

Related: BUG-057 (the details), FR-01 (order sanity), notes 34, 37, 62.
