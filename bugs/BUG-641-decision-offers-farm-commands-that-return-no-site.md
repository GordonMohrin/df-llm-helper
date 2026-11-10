# BUG-641 The thirst DECISION offers `bp sites farms surface=1` / `bp.place farms surface=1` that can never place
Status: fixed (offline, live-untested)
Severity: low (the player sends a command that answers 0 sites; the real options stay unnamed)
Found: 2026-11-10, Run 16c i3 Wallfree y387 (`bp sites farms surface=1 --fresh` -> 0 sites, 'farms rooms open from the dug Z4 floor of the fortcore'; the DECISION thirst command was never executable)
Module: `dfpilot/wake.py` (`workable_food_cmds`, `FARM_CMD`, `next_hint`)

## Actual
`economy.lua:3940` adds `M.FOOD_CMD.farms` to the `thirst` DECISION's `cmds`; BUG-459 filtered such commands for famine / food_low / mood_deadline / no_water / thirst_unit only, so the `thirst` hint offered the dead command, and a `bp sites farms ...` line was not recognised as a farm command at all.

## Root cause
`wake.py` `next_hint` (the id list in front of `food_hint`) lacked `thirst`; `FARM_CMD` matched `"tpl":"farms"` only.

## Fix
`thirst` joins the list; `FARM_CMD` also matches `bp sites farms`; when `plan.farm_site(urgent=True)` says `none` the farm commands are dropped and named ('not offered: bp.place farms: no farm site ...'); a thirst decision left without a trade command gets `TRADE_DRINK_CMD` (`trade.want add plant, drink, seeds`, valid per the schema), not the food one. The raw d.cmds of the event are unchanged (the kernel does not rank sites).

## Tests
`tests/test_bug637_641_f41_proj.py::test_the_thirst_decision_drops_the_farm_commands_when_no_farm_site_stands`

## Live check
In a fort with `bp sites farms surface=1` = 0 the thirst wake's `next:` shows the water commands and `trade.want` for drink and plants, and `[not offered: bp.place farms ...]`.
