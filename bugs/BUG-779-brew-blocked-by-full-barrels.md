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
- `brew_diag(K, inv)` carries `conts`; `brew_cause` answers `nobarrel` (fewer than `M.CX_FREE` = 3 free containers) after the 'a brewer works' check. `brew_watch` looks whenever `cont_free` is read and, while the cause holds, sets `p.contx` = {untl = now + 3 days, want 8..15} daily; it ends once 3 containers are free.
- Round 51 follow-up (verifier: the x4 order was the same as before): `M.plan_contx` (called first in `plan_containers`) orders ONE batch of up to `M.CX_BATCH` = 15 barrels in one work order on its own tag `dfllm:barrelx`, past every cap, on the wood floor, while the ordinary `dfllm:barrel` x4 order goes on beside it; with no logs it plans rock pots (`plan_pots`).
- Test of what the verdict can name: the verdict fires on `cont_free < 3` with the stall unmoved for 6 days; the i3 census showed 'empty' barrels (2-12) throughout, so whether those were held or unreachable is read nowhere in the log: they are what `cont_free` leaves out when a job holds them or no citizen reaches them.

## Open
The cause of the empties is not confirmed from logs (no census of the barrels' stockpile/job state exists at that moment; the kern.log rotated out 'barrel' detail). Food in full barrels is not moved into bins, and the food stockpiles that take freshly made empty barrels are not reconfigured: no act changes a stockpile's container settings, and writing one blind was judged too risky offline. Not run live; Kernel reload needed.

## Tests
`tests/lua/test_bug779_brew_barrels.lua` (6): all barrels full -> cause named, `contx` set, no order removed; empty barrels a job holds are no free container; 3 free -> no container verdict; 1 free -> verdict; census `cont_free`; `contx` makes `plan_containers` order a batch of 15 (`amount_total` 15, tag `dfllm:barrelx`) where the caps ordered none.
