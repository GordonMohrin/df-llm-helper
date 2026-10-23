# BUG-084 Autofarm stays off for good (or is enabled by every load) and nothing plants the fiber crops of the cloth chain
Status: fixed in 8d23f4c (offline, live-untested)
Severity: high (the Run 14 mood case again: no plant cloth, no thread for the strange moods, deaths)
Found: integration audit I3 (2026-10-23), DECISIONS 20 ("the thread/cloth reserve depends on autofarm's fibers: watch the live log")
Module: `lua/dfllm/economy.lua` (farm_fills, slot_crop, M.fiber_plan, M.fiber_note), `lua/dfllm/baseline.lua`, `config/baseline.json`

## Actual
B1 (BUG-058) disables autofarm below 30 food days or at a slot it emptied, enables it again from 90 food days after 14 days and
never after two wipes; a fort whose food stays between 30 and 90 days, a fort with `farms.autofarm: 'off'` and a fort with two
wipes keep autofarm off. B2's standing SpinThread / WeaveCloth / ProcessPlants and plan_cloth live on fiber crops; the thresholds
for them (T.farm) are autofarm's, and `slot_crop` plants the crop with the most seeds, a dye or a food crop. Nothing planted
flax, hemp, pig tail ... on purpose, and nothing said so.
Second path: `baseline.plan` runs on every load and enabled autofarm each time (`en:autofarm`), although economy keeps it off
(persisted `m.economy af.off`). Until the first daily run autofarm emptied the slots the kernel had filled; `T.slotnow` counted
those as autofarm's wipes (`af.wiped`): two loads and autofarm stayed off for good.

## Cause
`economy.lua` farm_fills / slot_crop (9bcb14f) know food crops and seed counts only; `baseline.lua` plan: `af_off` was true for the
config mode 'off' alone.

## Fix
- `M.fiber_plan`: while autofarm is off (`st.af_off`), cloth is short (`st.cloth.deficit`) and food is not (`food_low`), up to
  `economy.farms.fiber_slots` (2, 0-50; 0 = never) EMPTY slots a season take a fiber crop of `economy.cloth.fiber` with usable seeds
  (most seeds first, the plot's tile and the season decide as always); the fiber slots a season already holds count against the
  cap and a planted slot is never replaced. `slot_crop` gets the plan as a sixth argument; slotnow and farmslots pass it.
- `M.fiber_note`: kern.log once a week while autofarm is off and cloth is short: the deficit, the thread, why autofarm is off,
  the cap and the fiber seed kinds in stock.
- `baseline.plan`: with `economy.farms.autofarm` 'auto' the enable is skipped while `m.economy af.off` stands (read-only look at
  the persist key); 'off' as before, 'keep' unchanged.
- Safety: only empty slots, never in a food shortage, two slots a season at most; an old state has no `af`, nothing changes.

## Not decided offline
Whether two fiber slots a season are enough for the standing orders (30 a month): the weekly log line shows the deficit; raise
`fiber_slots` when it stays.

## Tests
`tests/lua/test_integration_i3_farm.lua` (the first test fails on 9bcb14f): two of three plots hold flax in spring and autumn,
the third the crop with the most seeds, the log line, the cap with a planted slot; no fiber in a food shortage, with
`fiber_slots` 0 or with autofarm on ('keep'). `tests/lua/test_integration_i3.lua` (fails on 9bcb14f): a load does not enable
autofarm while `af.off` stands; no record, 'keep': enabled as before.
