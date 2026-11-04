# BUG-382 drink falls to 0 beside plenty of food: nobody gathers plants for the stills
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3 Yawninggilt y375-376, `runs/run-16c/FR-BUGS.md`), main ec9bd8e
Module: `lua/dfllm/economy.lua`, `lua/dfllm/runner.lua`, `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`

## Actual
Two finished farms, yet `drink pre-alarm: 58 drink days (< 60): no brewable plants`, then `drink 150 d: 16 brews wait, 0 of 35
barrels empty` down to `drink 0 days` while food stood at 1,600+ days (fish). The farms had no seeds (`farm plot 17705: no seeds
for MUSHROOM_HELMET_PLUMP and no other crop with seeds grows there now`), the caravans never came (DEPOT_MISSING, BUG-368).

## Root cause
The only way plants reach the stills in a fort without seeds is gathering. economy's `gather_low` already adds gatherers to the
Plant gatherers detail for drink (BUG-042: `dlow`), but they need GatherPlants jobs, and those exist only inside the runner's
temporary `dfllm-gather` zone, drawn and kept by `runner.lua gather_zone` for low FOOD only (`fd < gather_below` 30, removed
above `gather_off` 120). i3's zone was drawn at food 23 d, removed at `gather zone removed (food 378 days)` and never again; with
`open < gather.min_jobs` the detail got no member either. Drink never counted.

## Fix
- economy: `M.drink_low` publishes `stock.bshort` (flag; contract + schema + CONTRACTS row + appendix): drink below
  `gather.drink_d` and the brewable plants (`brew_p + brew_g`) short of the drink deficit (`M.brew_need`, the condition of
  `gather_low`'s `dshort`).
- runner `gather_zone`: `bshort` draws the zone like low food (same rects on the walk group, not in winter), keeps it beyond
  `gather_off`, and removes it once the plants are back (`g.dr` marks a zone drawn for the drink: it goes when food is not low
  either). The log line says `, drink plants short`.

## Open
Needs revealed, reachable plants on the zone's levels and not winter; a fort without any wild plants in reach still waits for
the caravan. The seed side is BUG-381's `fd_wants` (seeds asked for when the kitchen has no cook crop).

## Tests
tests/lua/test_bug382_gather_drink.lua (2), tests/lua/test_economy_gather.lua (stock.bshort). Fail on ec9bd8e.

## Live check
i3-like: drink < 60 d with 0 brewable plants and food > 120 d: `food N days, drink plants short: gather zone ...`, GatherPlants
jobs appear, the Plant gatherers detail fills (`gather: drink N days ...`), `brew_p` rises, the zone goes
(`gather zone removed`) once the plants are back.
