# BUG-932 The kernel's barrel reserve orders once and waits behind the open order: no standing order against the free-empties target (i3 ~750 barrels, 4-6 empty)
Status: fixed (offline, live-untested)
Severity: high (i3 drink 14 d, the player's own MakeBarrel x20 lifted it to 241 d)
Found: Run 17 i3 Orangering (region1-site97, DF-test3), kernel 8c553a52 / 18032a02, `leitung/neu10/DIAGNOSE-i3-fasskur.md`, runs/run-17c/FR-BUGS.md "Runde 16"
Module: `lua/dfllm/economy.lua` (`M.plan_reserve`, `M.reserve_fill`, `M.fill_short`, `M.fill_say`, `M.reserve_stale`, `M.reserve_blocker`, `scan_orders`), `config/baseline.json` + `dfpilot/fairplay.py` (`economy.creserve.fill*`)

## Symptom (PROVEN, kern.log of region1-site97)
- ~750 barrels (765 at y505), 4-6 empty, drink 14 d; `why brew`: "order 35 BREW_DRINK_FROM_PLANT ... at least 5 empty food storage containers: 3 free by the census ... unmet".
- kern.log 203606849 `container reserve: 10 wood barrels ordered (DF cancelled brew 0x in 7 d; 4 brews open; 49 usable logs ...)`, 203606854 `order dfllm:barrelx x10`; then every week `container reserve: barrel order 2877 open 179 d (203 d, 420 d), 0 of 10 made: order 2877 MakeBarrel: conditions: no job made: 1 of 1 item condition met by my count (at least 1 wood: 1059 found, met), DF counts items its own way; 42 CARPENTER holders: 1 free, 31 busy ...` - while the player's own MakeBarrel order 2876 (x30, no item condition) beside it went 30 -> 13.
- The kernel's order carries `item_conditions {AtLeast WOOD 1}` (commands.log 1795712059: `act.workorder ... "item_conditions":[{"condition":"AtLeast","item_type":"WOOD","value":1}] ... "tag":"dfllm:barrelx"`), the player's `{"amount_total":20,"job":"MakeBarrel","material_category":["wood"],"tag":"dfllm:cmd"}` none.

## Cause (file:line before the change)
- economy.lua `M.plan_reserve` (`if open(r, tag) then ... return true end`): while the batch order stands the reserve waits, and only DF's own cancel count (`M.reserve_dead`, >= 10 cancels of "make wooden barrel / needs logs" since the batch) takes it back; MakeBarrel is in KEEP_JOBS, so nothing else does. An order DF's manager never makes a job for gives no cancels: it stood 420 game days.
- With the order gone, the next batch needs a FRESH DF cancel (`x`, cancels >= 5 in 7 days) and the gap / grace; when the cure's gate fell OFF the cancels were 0 (brews could not start: the item condition "at least N empty containers" kept the manager from making brew jobs), and the only path left, the trickle, orders ONE barrel per 20 days and is never reached behind an open order.
- INFERRED (not read from DF): the item condition `AtLeast WOOD 1` is why DF's manager made no job for order 2877; the live difference between 2877 (condition, 0 of 10) and the player's 2876 (none, 30 -> 13) is proven, the mechanism is not.

## Change
- `M.reserve_fill` (the standing fill): once the cure ran (`p.rsv.t0`) or DF names the shortage, brews are open and `cont_free < creserve.fill_free` (20): a WOOD barrel order sized to the shortfall, minus the barrels other owners' MakeBarrel orders still owe (`scan_orders` -> `s.xbarrel`), at most `fill_batch` (20) per order, `fill_season` (60) per 84 game days, never when the barrels already number `fill_per_cit` (30) per citizen, `fill_gap_d` (3) days after the last batch, only with usable logs above the wood floor (`floor_of`) and a Carpenter's workshop; independent of DF's cancel count; bounded also by `total_cap` a game year (unchanged). The order carries NO item condition. Replaces the 20-day trickle where it applies (`fill = false` gives the trickle back; with no log the trickle of ROCK stays as fallback).
- `M.reserve_stale`: the reserve's wood order that stood `fill_stale_d` (28) days with nothing made, while logs are usable and the empties under the target, is taken back ONCE (`act.order_remove`); every wood order after it is condition-free (`rs.nocond`); a condition-free order is never taken back (the blocker is another).
- `M.reserve_blocker` (jobwhy's real blocker once a week, existing since BUG-918 D4) now also runs while the free empties are under the target, not only with the container gate ON. Every refusal of the fill (no log, no shop, barrels per citizen, season cap) is one kern.log line a game week: `container reserve (standing fill): ...`.

## Tests
`tests/lua/test_bug932_fill.lua` (7: i3 numbers, the player's order counted, bounds and weekly lines, old paths, blocker line with the gate OFF, `scan_orders`, the stale order and the condition-free replacement), `tests/lua/test_bug854_reserve.lua` unchanged and green (trickle kept for rock).

## Live-Erwartung
i3: with `cont_free` 4 and the cure run: kern.log `container reserve: 17 wood barrels ordered (standing fill: 4 free empties, 20 wanted; ...)` and `order dfllm:barrelx x17`; the old 2877 gets `container reserve: barrel order 2877 stood 420 d with 0 of 10 made ...: taken back, the next one carries no item condition`; the new order is worked like the player's (amount_left falls). Every week while empties stay under 20 and the order stands: one `container reserve: barrel order N open D d, 0 of K made: ...` line with the blocker. At 750 barrels / 31 citizens (24 a head) the per-citizen cap (30) is not reached; the season cap ends the orders after 60 barrels in 84 days with `container reserve (standing fill): 60 barrels ordered in this season ...`.

## Not proven
- That the missing item condition is what makes DF work the order (see Cause); if the new condition-free order is also left unworked, the weekly blocker line names why.
- That free empties STAY free: on i3 every new barrel was taken by the plant piles at once (empties 5-7 whatever was made); the fill only adds barrels, the registration (BUG-918 / BUG-930) is the other half.
