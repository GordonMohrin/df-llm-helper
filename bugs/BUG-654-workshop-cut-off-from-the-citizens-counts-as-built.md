# BUG-654 A workshop no citizen can walk to counts as built: meals 0 for years, no new kitchen asked for
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16a i1 Basementflew y459-y466 (meals 0 beside 3,323 food days; `inspect workload` `unreachable PrepareMeal x1`, also ConstructChest, ConstructMechanisms), Run 16b i2 Valleyhame y377-y381 ('kitchen idle with 15 cook ingredients (order made again)', meals 0, 11 hungry)
Module: `lua/dfllm/economy.lua` (`facts`, `M.shop_reach`, `M.cut_scan`, `M.cut_text`, `food_block`, `hungry_warn`, `inspect workload`), `dfpilot/wake.py` (`PLACE_KEYS`), `dfpilot/plan.py` (`request_facts`)

## Actual
Basementflew's manifest lists a full shop set on z117 (Kitchen 29,112,117, Carpenters 33,108,117, Masons, Mechanics, Still, Butchers, Fishery, Craftsdwarfs) and the surface kitchen 78,100,131 under `gone` (destroyed). z117 is the flooded level: its shops stand on a walk group no citizen is on (player, y464: the only Kitchen lies outside the citizens' group 4357). Every kernel fact said `workshop:Kitchen` = true, so `cook_watch` switched labors on and remade the meal order (BUG-629) again and again (`cooking still stalled 37 days`, food order x17 open), the food decision said 'raw food is not cooked', `food_shops` / `mandatory` / `missing` requests never asked for a second kitchen, and `inspect workload` only counted 'unreachable PrepareMeal x1' without naming the shop. The same fact hid the other cut shops: the manager hands a shop one job at a time, so the cut-off Carpenters held a ConstructChest and the hospital's beds waited behind it (BUG-655).

## Root cause
`lua/dfllm/economy.lua` `facts()` (was line 1340) sets `f['workshop:<Type>']` for every BUILT shop in `WORKSHOP_ANY`; nothing asks where the shop stands. All consumers (`ws_any` at about 60 places: cook_watch, food_block, ws_missing, piece_route, stage gates, request pacing) take the fact as 'the fort has that shop'.

Evidence that the kitchen's reach, not the ingredients, is the problem: the gamelog of the fort carries 'cancels Prepare easy meal: Needs unrotten cookable solid item' about 2,000 times in its last 150 MB (DF's own item search from the kitchen finds nothing it can walk to) and 'Cook cancels Prepare lavish meal: Needs unrotten cookable item in linked stockpile' 339 times, while the kernel counted 3,234 cook ingredients (census: reachable by the citizens, not by a kitchen in another walk group).

## Fix
- `M.shop_reach(K)` (daily, in PEACE): for every built workshop the ring of tiles round its footprint, read through `snapshot.groups`; a shop is ON a citizens' walk group when one ring tile is on a home group (`home_set`), CUT when ring tiles have a walk group and none is a home group, unknown (never cut) when no ring tile has a walkable group or the module / the citizens cannot be read.
- `M.cut_scan`: a type whose EVERY shop is cut for `M.CUT.days` (3) days is confirmed (`p.cutws[Type] = {t, at, grp, home, n}`, persisted); a shop of the type on a home group (a new one) or no shop at all ends it. Not judged outside PEACE (a lockdown or a raised bridge splits the groups).
- `facts()` drops `workshop:<Type>` for a confirmed type and sets `cut:<Type>`: the shop requests, order stalls ('no Carpenters workshop'), piece routes ('no Carpenters'), stage gates and `cook_watch` treat it as missing.
- (a) Reported: ORDER_STUCK (B, kind `workshop`, job = the type) 'workshop Kitchen at 29,112,117 (walk group 9, the citizens on 7): no way for the citizens, counted as missing', kern.log; `inspect what=workload` data `shops_cut` ([{type, at, grp, home, n, days}]) and the line 'workshops cut off: Kitchen at ...'; the food decision 'Kitchen cut off: ...' / 'new Kitchen requested, the old one is cut off: ...'; `hungry_warn` 'kitchen cut off (...)'.
- (b) New shop: `M.ws_ask(K, p, 'cut', types, request_days)` = PROJECT_REQUEST workshops why=`cut`, types = the cut types `M.WS_PLACE` can place (paced with backoff, not while a workshops project builds the type). follow places it with `need` = the types (kept although the manifest lists the cut one); the surface variant (BUG-394 `workshop_tries`) ranks only floor on the citizens' walk group (`walk_at`). `plan.request_facts` keeps a cut type the manifest has, so `plan propose` drafts `workshops` for it too.
- (c) The rebuild is not refused for a finished project: BUG-656.
- `wake.PLACE_KEYS` lacked `manager`, `missing`, `gear`, `well`, `masonry`, `trade` (and would lack `cut`): the follow job of a workshops request is keyed by its why, the snapshot came, `_on_snapshot` matched no job and NOTHING was placed (BUG-231, BUG-267, BUG-270, BUG-473, BUG-630 all end in this path; their tests stop at the snapshot request). All seven are listed now. This switches on placements that never ran live: each is paced by the kernel's `ws_ask` backoff and cooldown.

## Tests
`tests/lua/test_bug654_656_cut_shops.lua` (5: cut after 3 days and told once, decision text and no stall watch, a shop on the home group / a second one ends it, unknown ring and no snapshot module are no cut, 4 types in one request and `inspect workload`), `tests/test_bug654_656_f43_cook.py` (follow places a new Kitchen although the manifest lists one, `request_facts`, PLACE_KEYS).

## Live check
Basementflew (after a reload): within about 4 game days kern.log 'workshop Kitchen at 29,112,117 ...: no way for the citizens', ORDER_STUCK kind workshop for Kitchen, Carpenters, Masons, Mechanics, ..., one PROJECT_REQUEST workshops why=cut, `auto:cut` in cli.log and a workshops project on the surface; `inspect what=workload` `shops_cut`; meals rise once the new kitchen stands and the order goes through.

## Open
- Valleyhame (i2) is NOT proven to be this: there the logs show a kitchen with 3-18 cook ingredients, COOK held and 20 PrepareMeal orders open, food 0-7 days, 'CABBAGE:LEAF: no food use' for 501 cabbage leaves (the raws confirm it: only the cabbage plant itself is EDIBLE_COOKED, the leaf growth is not) and no unreachable job in any log; the scarce farm yield was the shortage. If a stall persists with a reachable kitchen, the 'cooking still stalled' line and `inspect workload` now show it.
- The new kitchen is ranked by the surface ranking (distance from the middle of the snapshot, +60 near the entrance, on the citizens' walk group); 'near the food stock' is not implemented (the request carries no position).
- A flooded corner that dries within 3 days is never cut; one that floods for good is. Outside PEACE nothing is judged.
- A cut-off shop stays on the map; the kernel does not take it down (a drained hall may serve again, and then counts again).
