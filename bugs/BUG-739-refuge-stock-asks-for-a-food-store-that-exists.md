# BUG-739 REFUGE_STOCK says the refuge level has no food store template, but refuge_drink food=1 is one
Status: fixed (offline, live-untested)
Severity: medium (the refuge check could not reach 100 %; the player got no command)
Found: 2026-11-11, Run 16b i2 Whirledrampart y431 (`REFUGE_STOCK` #11191: "Tiefe+ holds food 62/68 ... the refuge level has no food store template: stock it from the next plan (refuge_drink holds drink only)")
Module: `lua/dfllm/seal.lua` (`RF.floor`)

## Actual
Tiefe+ held 686 drink and 62 of 68 food; the standing floor named no command, only "no food store template", although BUG-572 (R36) made `refuge_drink` with `food=1` a food AND drink store (`plan propose` drafts it).

## Root cause
`lua/dfllm/seal.lua` `RF.floor` (the `cmd` choice for the refuge burrow, about line 1356): the branch for a food shortage of the refuge returned a fixed text; only the drink case had a command. The text predates BUG-572.

## Fix
`RF.floor`: a food (or food+drink) shortage of the refuge names `dfllm cmd bp.place '{"tpl":"refuge_drink","site":"S1","p":{"n":N,"food":1}}'`, N = barrels of 5 units for what the burrow lacks (missing food, plus missing drink for food+drink), 2..40 (the template maximum). The drink-only case and the Kern+ stockroom command are unchanged. The command is the existing one; no new actuator.

## Tests
`tests/lua/test_m2_refuge.lua`: Tiefe+ short of both (30 + 30 units: n 12, food 1) and short of food only (food 0 of 30, drink 40: n 6), replacing the old fixed-text assertion.

## Live check
A refuge with food under the floor: the REFUGE_STOCK line carries the `bp.place refuge_drink ... "food":1` command; once it is built the refuge check reaches 100 %.
