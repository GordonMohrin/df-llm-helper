# BUG-255 Year 1 without a Still: drink falls for 60 game days, the kernel only asks (drink_low)
Status: fixed (offline, live-untested)
Severity: high (G4/G5: drink 161 -> 41-55 days in the first year; the player placed the Still by hand)
Found: 2026-10-29, Run 15 Inkintense (spr d24 `drink 161d! drink: no still`, #37 DECISION_NEEDED drink_low `55 drink days ... no brew order` block=brew) and Drillchamber (`drink 41d, keine Still`, sum d22), fix6-food-drink
Module: `lua/dfllm/economy.lua` (`M.drink_low`, new `M.drink_fix`)

## Actual
`drink_low` named 'no still' as the player's blocker and emitted DECISION_NEEDED only; nothing requested a Still. The
year-1 plan drafts fortcore stage 1 only, so the Still of P0 came late or never; the game session ran `bp.place workshops
only=Still` by hand.

## Fix
Below `drink.low_d`, no Still on the map and no pending workshops/fortcore-1 project that builds one (`M.fishery_proj`, BUG-206):
`PROJECT_REQUEST workshops why=mandatory types=[Still]` (+ `Kitchen` while food is below 60 days and no kitchen stands); follow
places it as for FR-76. At most every `food.request_days` (14) and twice an episode (`p.still_req`), then the question is the
player's again. While the request is fresh the Still is `auto: still` (Still requested), not a blocker. The plan.py year-1
draft is not changed here (fix6-plan-propose).

## Tests
`tests/lua/test_economy_food_run15.lua` `BUG-255: ...`; `tests/lua/test_economy_drink.lua` BUG-042 pin updated (fail on 2b9c009).

## Live check
A fresh fort without a Still below 60 drink days: `dfllm events --type PROJECT_REQUEST` `workshops Still: drink N days and no
still` (d.why mandatory, d.types [Still]), cli.log `auto:mandatory ... placing workshops`, kern.log `request workshops Still (1/2)`;
the drink_low line says `auto: still`.
