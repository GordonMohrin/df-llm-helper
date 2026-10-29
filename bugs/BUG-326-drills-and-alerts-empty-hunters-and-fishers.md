# BUG-326 drills at 30-42 food days and every alert empty the hunters and fishers
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 3)
Module: `lua/dfllm/drill.lua` (M.SUPPLY_MIN, M.supply_sample, M.supply_hold), `lua/dfllm/economy.lua` (hunt_want, fish_want, M.hunt_siege, tools at_once, on.MODE, T.plan)

## Actual
Run 15c Inkintense y376 winter (food 0-11 d the year before, no farms, the fort lives on fish and game):
- MODE #1714 `PEACE>DRILL drill: auto: retry` at food 35 -> 42 d (kern.log 151975959 `famine hold over (food 35 d >= 30)`,
  151975992 `food 42 days`); WORK_DETAIL #1717-#1721 took both hunters and all three fishers off (`mode DRILL, target 0`).
  #1883 the next automatic drill at food 31 d, falling to 24 d (kern.log 152070571, 152078732 `food pre-alarm: 24 food days`),
  #1887-#1890 the same four off again. BUG-294's hold (drill.lua:420 `SUPPLY_MIN = {food_d = 30, drink_d = 30}`) let both pass.
- seven short ALERTs y376-y377 (#1764-#1867) took them off each time (#1769-#1772 `mode ALERT`), and the SIEGE of two lone
  goblins (#1583/#1584 `mode SIEGE`) took the hunters for three days.

Root causes: drill.lua:420 the famine threshold of 30 days and no trend; economy.lua hunt_want (1702/1704) and fish_want
(1742) wanted 0 hunters/fishers in every mode but PEACE/RECOVERY with reason `mode`, and tools (4261) took every member off
at once for that reason; BUG-295's restore list was only kept for a DRILL and only restored in PEACE.

## Fix
- drill: no automatic drill below 60 food or drink days (`supply: food 42 d`), nor while that stock falls below 120 days
  (lower than the oldest of the daily samples over 7 days, persisted `m.drill` `sh`; `supply: food falls 100 d`). The player's
  `drill` stays his choice.
- economy: hunters and fishers keep their detail in DRILL, ALERT and RECOVERY (why `hold`: the members stay, nobody joins;
  the civil alert keeps them in Kern+). Only a real siege (SIEGE or BREACH that is not reflex's lone harmless picture,
  `reflex.lone_ids`) takes them off at once (`mode SIEGE`, kept in `p.drill_off`); they go back on their detail as soon as the
  mode is no SIEGE/BREACH any more (RECOVERY included) or the siege turns out to be the lone harmless picture (the next economy
  run), WORK_DETAIL why `drill over`. Only a siege rushes the next tools run.

## Tests
`tests/lua/test_fix13_hunters.lua` (4 tests), updated `test_economy_chains.lua` (hunters), `test_economy_food.lua` (fishers),
`test_fix10_economy.lua` (BUG-295). All fail on 1d17c7e.

## Live check
Inkintense: `dfllm status` shows `drill never (auto: supply: food NN d)` while food < 60 d, `supply: food falls NN d` while it
falls below 120; at the next ALERT `dfllm events --type WORK_DETAIL` shows no `mode ALERT` off line; at the next real SIEGE
`Hunters - ... (mode SIEGE ...)` and at SIEGE>RECOVERY `Hunters + ... (drill over, back from the drill)`. Uncertain: whether
a goblin pair counts as reflex's lone harmless picture (body size 60000 > harmless_size 20000: probably not, then it is a real
siege and they go off as before, but now come back at RECOVERY).
