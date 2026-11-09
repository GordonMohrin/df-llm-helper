# BUG-597 640 drinks and 14 food stay forbidden in a BREACH
Status: fixed (offline, live-untested)
Severity: high (drink and food the confined citizens cannot use)
Found: 2026-11-09, Run 16b i2 Brotherarrow y414 (BREACH, `unforbid held back: mode BREACH`, round 36's unforbid did not apply)
Module: `lua/dfllm/economy.lua` (`T.forbid`, `M.confine_burrows`)

## Actual
In the BREACH the stock stayed forbidden: 640 drinks and 14 food items, `stock.dfwhy` `mode BREACH`.

## Root cause
`T.forbid` ran in PEACE / RECOVERY / ALERT / DRILL and, since BUG-570, in a SIEGE with a hunger emergency (`siege.starve_state`, SIEGE only). A BREACH never passed the mode gate, and a SIEGE without the emergency did not either, although the citizens were confined to a burrow that held the stock.

## Fix
`economy.confine_burrows`: in a SIEGE or BREACH with the civ alert sounding, the ids of the burrows of the confinement (`siege.alert_names`, the care burrow left out). `T.forbid` then runs: loose food and drink, containers and seeds inside those burrows are unforbidden (up to `FORBID_STARVE_PER_DAY` 200 a day), what lies outside stays forbidden (`stock.dfwhy` `N kept outside the confinement burrows`). seal refuses a burrow with a hostile in it, so the stock inside is not in the enemy's reach.

## Tests
`tests/lua/test_bug595_597_refuge_siege.lua` (4) (BREACH and SIEGE: inside freed, drink and food, outside kept); `test_economy_supply.lua` (FR-50 and BUG-570 SIEGE cases unchanged: no alert, no change).

## Live check
A BREACH: kern.log `unforbidden: ...` within the first day, `stock.dforb` falls to what lies outside Tiefe+.

Related: BUG-506, BUG-570, BUG-594
