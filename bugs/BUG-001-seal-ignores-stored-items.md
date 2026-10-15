# BUG-001 `seal` ignores drink, food and seeds stored in barrels, so every burrow audit fails
Status: open
Severity: high (the alert burrow audit refuses every burrow, so a siege confines nobody; CUTOFF for food, drink and seeds can never fire)
Found: 2026-10-15, Run 9 save autosave 1 (Udosoddom, y363), dfpilot main 3edc277, live test by Claude
Module: `lua/dfllm/seal.lua:54` (`SKIP` contains `in_inventory`), used by `usable_` (line ~236) in the item pass of the reach audit (line ~395)

## Expected
Drink, food and seeds inside barrels, bins and bags count for the reach classes `drink`, `food`, `seeds` and for the
per-burrow drink and food totals. Only items carried or worn by a unit are skipped.

## Actual
Items stored in containers carry `flags.in_inventory`, so `usable_` skips every one of them (economy.lua's `SKIP` does
not contain `in_inventory` and counts them). The result:

```
$ python -m dfpilot cmd inspect what=reach
... "drink":{"groups":[],"main":0,"n":0,"off":0}, "food":{"groups":[],"main":0,"n":0,"off":0}, "seeds":{"groups":[],"main":0,"n":0,"off":0} ...
$ python -m dfpilot cmd inspect what=refuge
alert PEACE: no confinement, 0 tiles, 0/5 inside (Kern+: drink 0<5, food 0<5)
"Kern+":{"beds":54,"drink":0,"inside":5,"ok":0,"tiles":6960,"why":"drink 0<5, food 0<5"}, "Innen+":{... "drink":0 ... "ok":0}
$ python -m dfpilot status
... | alert no confinement (whole fort) (Kern+ refused: Kern+: drink 0<13, food 0<13)
```

Same tick, Lua check (`dfhack-run lua`): 1362 drink units, all 1362 on `Kern+` tiles (`dfhack.burrows.isAssignedTile`),
0 forbidden (item or container). The fort had `stock drink 2773d` in the same `status`.

## Cause
`SKIP = {'forbid', 'trader', 'removed', 'garbage_collect', 'in_inventory', ...}` in seal.lua. A drink unit inside a barrel has
`flags: in_inventory, weight_computed` (read in Run 9). So the whole stock is dropped.

## Consequences
- `alert_burrow` always falls back to "no confinement (whole fort)": the civil alert does nothing in a siege.
- `refuge` can never choose `Tiefe+` (REFUGE_FAIL would fire for the wrong reason).
- CUTOFF (citizens lose the group of their food, drink or beds) is blind for food and drink.

## Fix proposal
Skip `in_inventory` only when the holder is a unit (`dfhack.items.getHolderUnit(it) ~= nil`); for an item inside a
container check the container (`getContainer`, forbid, `in_building` of the container is fine) and use the container's
position (`getPosition` already returns it). Add a Lua test with a barrel holding drink.

Related: FR-59, FR-37, FR-57, BUG-006
