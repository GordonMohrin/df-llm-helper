# BUG-834 a fort with thousands of plants died of thirst: every empty barrel is filled with plants by the food piles, the container verdict missed 3 and 7 'free' barrels
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-24, Run 17 i1 Diedplank y380 (4 dehydrated in a year, drink 0 d, '3 empty barrels, 3472 plants, 32 brews open', kern.log 3135/3275/3659/4048 'order 414 ...: validated, a workshop has room, no condition, no job yet') and i2 Whirledrampart y485 (321 barrels, 7 'empty' at ticks 194099568 ... 196310736, brew_p 6978, 'brews ordered, none ran for 508-930 days')
Module: `lua/dfllm/economy.lua` (`M.cx_reserve`, `M.CX_PHANTOM_D`, `M.brew_cause`, `M.brew_watch`, `M.cx_freeze`, `M.cx_end`, `M.cx_active`), `lua/dfllm/act.lua` (`pile_barrels`)

## Root cause
Confirmed from the live logs: (1) BUG-779's verdict `nobarrel` needs `cont_free < 3`; i1 counted 3 and 4 empties, i2 7-12, so `grep 'barrels at once|no empty barrel or pot'` finds 0 lines on both forts and every stall reads `nojob` (economy.lua `M.brew_cause`, `M.CX_FREE`). (2) The 7 (i2) / 3 (i1) 'empty' barrels never change over thousands of days: DF takes none of them for a brew and the haulers do not fill them either (a census count that stands still is not a barrel). (3) No code limits barrels in the plant stockpiles; the haulers (StoreItemInBarrel in the brewers' job lists) fill each new barrel with plants (the player saw new barrels filled at once, i2 FR-BUGS). NOT confirmed: the settings of the live piles (the live `max_barrels` was never read).

## Fix
- Reserve instead of the constant: `M.cx_reserve(brews open)` = a quarter of the brews open (3 at least, `CX_BATCH` 15 at most); i1 (32 brews) needs 8 free, 3 is a stall.
- Phantom: `brew_watch` counts the days the free count stood still (`bw.fd`); `CX_PHANTOM_D` (12) days make the census count worth 0 (`brew_cause` text 'N free by the census, unchanged for D days: DF takes none of them'); any move of the count or of the open brews resets it.
- While the verdict holds the plant stockpiles take no new barrel: new act `pile_barrels('freeze')` (stockpile sheet `max_barrels` of the food piles that take no drink, never `dfllm-drink`; set to the barrels lying in the pile now, nothing is moved); in a drink emergency (drink under `CX_EMERGENCY_D` 10 days) piles that also take drink are frozen too. The old limits are kept in `p.pilecap` and written back by `cx_end` when the stall is over (the containers are back, the brews moved, no brew order is open).
- `p.contx` lasts `need + 2` days (it lapsed 3 days into every 6-day look) and carries `res`, `ph`, `since`; `cx_active` uses them.

## Tests
`tests/lua/test_bug834_838_brew_chain.lua` (i1 census: 3 free, 3472 plants, 32 brews -> container verdict, freeze, reserve 8; 3 free beside 5 brews is none; the emergency freezes mixed piles; i2: 7 constant 'free' -> phantom after 12 days, a moving count is none; restore with the old limit; act.pile_barrels on a fake stockpile vector).

## Live-Erwartung
1. On a fort like i1/i2 the next brew stall line says `no empty barrel or pot for a brew (... unchanged for N days: DF takes none of them)` instead of `the manager gave no Still a job`, and kern.log has `brew stall: stockpile N (name) takes no new barrel: limit A -> B` (that line also tells the live `max_barrels` semantics).
2. Within 10 game days after that line `cont_free` (census / `inspect census`) rises to at least the reserve (8 for 32 brews) and stays (empty barrels are no longer refilled with plants); `drink_d` rises.
3. If after 10 days the freeze line exists but empties still do not stay: `max_barrels` is not the lever; read the pile with `dfpilot why brew` and the jobwhy facts (BUG-836).
