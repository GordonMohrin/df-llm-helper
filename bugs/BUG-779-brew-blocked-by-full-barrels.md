# BUG-779 Brewing blocked: every barrel holds food, the stall never names it and nothing orders a barrel past the caps
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Lancemoment y379-y380 (run-16c STAND 20:54: drink 0 d, 'Needs empty food storage item', 48 barrels full of food, 3,444 food / 2,062 meals; the player ordered `order.add MakeBarrel` 5+10 by hand, brewing ran afterwards)
Module: `lua/dfllm/economy.lua` (census BARREL / TOOL branch, `M.brew_diag`, `M.brew_cause`, `M.brew_watch`, `plan_containers`)

## Actual
The Stills held jobs that waited for an empty food-storage item; no barrel was free and drink fell to 0 days. The kernel log only said 'N brews wait, 4 of 15 barrels empty'; the 'empty' census counted any barrel without contents, also one a job holds or nobody can reach.

## Root cause
`economy.lua` `plan_containers` (caps `max_total` 30 / `grow_total` 80 against the barrels in total, wanted empties `min_empty` 4) and `brew_watch` (it looked only when `inv.barrels_empty > 0`) with `brew_cause` (BUG-767): nothing checked for a container a Still job can take, so with no free barrel the watch returned silently and the barrel order stayed inside the caps.

## Fix
- Census: `cont_free` = empty barrels and pots that no job holds and that a citizen can walk to.
- `brew_diag(K, inv)` carries `conts`; `brew_cause` answers `nobarrel` ('no empty barrel or pot for a brew (N barrels, M pots; E empty, none free: ...): DF says "Needs empty food storage item"') after the 'a brewer works' check and before suspended / untaken. `brew_watch` looks whenever `cont_free` is read and, while the cause holds, sets `p.contx` = {untl = now + 3 days, want 4..12} daily; it ends when a free container exists. The brew orders are left alone for this cause.
- `plan_containers` with `p.contx` and no free container: wanted empties at least `contx.want`, cap grown past the barrels, the wood floor may be used, and without logs rock pots (`plan_pots`) are ordered.

## Open
Food in the full barrels is not moved into bins or a food stockpile (no act for hauling). Not run live; Kernel reload needed.

## Tests
`tests/lua/test_bug779_brew_barrels.lua` (5): all barrels full -> cause named, `contx` set, no order removed; empty barrels a job holds are no free container; a free barrel -> no container verdict; census `cont_free`; `contx` makes `plan_containers` order barrels where the caps ordered none.
