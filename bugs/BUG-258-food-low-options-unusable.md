# BUG-258 food_low options unusable: a fishing zone without water, hunting 'bolts' with 175 bolts and no crossbow
Status: fixed (offline, live-untested)
Severity: medium (the player was sent to options that cannot work)
Found: 2026-10-29, Run 15 Inkintense (#151 block [cook, fish_zone, hunt, farms] in a fort without a brook; census bolts 175, w_xbow 0), fix6-food-drink
Module: `lua/dfllm/economy.lua` (`M.food_block`, `M.FOOD_OPTS`, `M.FOOD_MORE`, the fishing scan record)

## Actual
`food_block` listed `fish_zone` whatever the fishing scan found and mapped every hunt blocker to the option `bolts`, even
`hunt: no crossbow` with 175 bolts in stock; the butcher option had no verb.

## Fix
The scan record keeps `seen` (every water tile met: fishable, frozen, cavern, shallow); with `seen` 0 the fishing zone is no
blocker and no option (frozen or cavern water still is). No crossbow is its own blocker `xbow` (`hunt: no crossbow, no Bowyer's
workshop (N bolts)` or `hunt: no crossbow (N bolts)`; `auto: xbow` while dfllm:gear_xbow orders are open) with the option
`crossbow`; `bolts` only when a crossbow exists. `butcher` became `butcher.mark` (BUG-260).

## Tests
`tests/lua/test_economy_fishing.lua` `BUG-258: ...` and the Run 11 pin updated (fail on 2b9c009).

## Live check
Next food_low in a fort without water: d.block has no fish_zone, d.opts no `fishing zone`; with bolts and no crossbow d.block
`xbow` and the q text names the Bowyer's workshop.
