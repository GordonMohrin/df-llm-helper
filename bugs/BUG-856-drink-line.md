# BUG-856 status 'drink 0d' beside 74 drink units in the census and an alert of 32 d: three numbers for one stock
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17d i4 Girderroots y394 sum d1 (`runs/run-17d/STAND.md`): 'Trinken status 0d (census drink 74 Einheiten, Alarm meldet 32 d)'.
Module: `lua/dfllm/economy.lua` (`classify`: `drink_far`; state `stock.dfar` / `stock.dall`), `dfpilot/brief.py` (`supply_items`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Root cause
The three computations: (1) `T.days` / `stock.drink_d`: `inv.drink` (units that are reachable and not forbidden; a drink unit on another walk group or in a forbidden container is left out) divided by the 7-day moving consumption (seeded 53 milli-units per citizen and day); (2) the player's 'census drink 74' = the raw units the fort holds, forbidden and out-of-reach ones included; (3) the alert's 32 d is 74 units at the seeded rate (74 / (43 citizens x 0.053) = 32 d): the same division as (1) over the larger count. The difference is the reachability rule, and no text named it (only forbidden units had `dforb`; out-of-reach units went into one counter `unreach` shared with food). The alert's own source was not found in the code (seal's `core_d` is `drink_d x inside / total`, so it also reads 0); the 32 d matches the seeded rate over 74 units, which is what `dall` now states.

## Fix
One rule stays for `drink_d` (usable = reachable and not forbidden), but the others are named: census `drink_far` (drink units out of reach), state `stock.dfar` and `stock.dall` (the days the same rate gives with every unit counted: usable + forbidden + far). `brief` adds a line `drink 0d counts only usable units; not counted: 74 out of reach (another walk group or no walk tile), 5 forbidden (all of them at the same rate would be 32 d)`. The existing forbidden line (`N drink items forbidden ... NOT in the days above`) is unchanged.

## Tests
`tests/test_neu7_vorrat.py::test_drink_line_names_the_units_it_does_not_count`; the contract tests (state schema, `lint`).

## Live-Erwartung
Where drink units lie on another walk group (i4 y394 style): `status` shows the extra line with `dfar` and `dall` (PROMISED: it appears only with `dfar` > 0; where all drink is usable nothing changes). NOT promised: that the alert text of other modules names the units; a `dall` equal to the number a player computes by hand (it uses the kernel's 7-day rate).
