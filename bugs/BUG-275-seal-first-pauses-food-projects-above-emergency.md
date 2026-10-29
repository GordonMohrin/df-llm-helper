# BUG-275 seal first paused farms and food shops at food 27 d / drink 20 d (only below 30 counted)
Status: fixed (offline, live-untested)
Severity: medium (no kitchen, no still in the first year; DECISION_NEEDED food_low)
Found: 2026-10-29, Run 15 Drillchamber (y372), fix6-runner-seal
Module: `lua/dfllm/runner.lua` (`Q.low_supply`, `conf` `supply_d`, `paused`)

## Actual
kern.log:100 (y372 summer): the seal paused the farms project c1a187433a25b12d07 while food and drink were above the
emergency line (`seal_first.food_d`/`drink_d` 30); 20 days later food 27 d, drink 20 d, no kitchen, no still (DECISION_NEEDED
food_low). Food projects only ran once the fort was already in the emergency.

## Fix
Food and drink projects (farms, cistern, stockroom, refuge drink, food/drink workshops) run beside an open seal while food or
drink days are below `seal_first.supply_d` (60, config baseline.json runner.seal_first, 0..400); kern.log `(food 40 d < 60:
food/drink projects go on)`. The emergency rule (30) is unchanged.

## Tests
`tests/lua/test_runner_seal_fix6.lua` `BUG-275 ...` (fails on 2b9c009).

## Live check
A fort with food 30-59 days and an open seal: farms rows not `paused: seal`, the kern.log line names the food days.
