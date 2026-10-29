# BUG-259 Drink 0 days all year: thirst DECISION every 7 days with 0 thirsty, no plants asked for
Status: fixed (offline, live-untested)
Severity: medium (a wake every 7 days, the supply brake all year, the brewing gap never addressed)
Found: 2026-10-29, Run 15 Drillchamber (win d46 `drink: no brewable plants`; DECISION thirst #205/#212/#216/#223 `0 citizens thirsty, drink 0 days`), fix6-food-drink
Module: `lua/dfllm/economy.lua` (`alarm_check`, `M.drink_low`, `M.drink_why`, new `M.fd_wants`, `M.trade_wants`)

## Actual
`alarm_check` woke DECISION_NEEDED thirst and held `economy.alarm` (the tempo brake) on `drink_d < alarm.days` alone, while the
dwarves drank at the brook (thirst timers low); drink_low stayed silent below the alarm line, so 'no brewable plants' started
nothing.

## Fix
Low drink days alone are no alarm and no thirst wake: one citizen past `alarm.thirst` is needed (an unreadable census keeps
the old rule); kern.log `drink N days but nobody thirsty: the citizens drink water` once; the status drink line (stock.dwhy)
adds `nobody thirsty: they drink water`; drink_low keeps asking below the alarm line in that case. Below `drink.low_d` with no
brewable plant: `plant` x20 and `drink` x40 in economy's caravan wants. A gather zone is not painted (not built). The siege
`Kern+ refused: drink 0<17` check is siege's and unchanged.

## Tests
`tests/lua/test_economy_food_run15.lua` `BUG-259: ...` (fails on 2b9c009); `tests/lua/test_economy.lua` supply alarm still green.

## Live check
Drillchamber: no DECISION_NEEDED thirst while `0 thirsty`; `dfpilot status` drink line `...; nobody thirsty: they drink water`;
`economy.alarm` nil (no brake); the next caravan's wants list plant and drink.
