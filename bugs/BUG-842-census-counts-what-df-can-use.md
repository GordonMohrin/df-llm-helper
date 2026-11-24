# BUG-842 the census counted stock DF cannot use as free (183 logs on unwalkable tiles, 7 phantom barrels)
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: census wood 183 while 198 of 204 logs lie on tiles with no walk group (0 usable, DF 'Needs logs' for doors, buckets, cabinets, crafts); i2 Whirledrampart: 7 'free' empty barrels unchanged for ~700 game days while DF cancels every brew 'Needs empty food storage item' (348 barrels, 322 full, 8 forbidden, 11 in buildings, 4 trader).
Module: `lua/dfllm/economy.lua` (`classify`: WOOD, BARREL, TOOL pot; `ZERO`, census `far`, `M.state` stock fields), `lua/dfllm/snapshot.lua` (`M.far` second result), `dfpilot/brief.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Root cause
`classify` read WOOD, empty barrels and pots with the plain `far` test, which calls a tile without a walkable group 'near' (BUG-665 made only the boulder census strict); a log held by a job and the logs DF skips (in a building) were not counted apart, so nobody could say 'N of M'.

## Fix
Logs, empty barrels and empty pots use `far(it, true)` (a tile with no walk group is out of reach; the same snapshot call as before, no extra map read); logs held by a job are `wood_busy`, logs DF skips are `wood_skip`, the unwalkable ones also `wood_nw`. State `stock.wood` / `woodt` and `stock.cont` / `contt` appear only where usable differs from total; status shows 'wood 0 usable of 204' and 'containers 0 usable of 7 empty'. `economy.treeless`, the wood floors and orders now see 0 logs on i1 (the treeless path asks the caravans for wood after treeless_days). Cost: none added per item (the strict flag replaces the plain call).

## Tests
`tests/lua/test_neu4_cancel.lua` (i1: 204 logs -> wood 0, far 199, nowalk 198, skip 5; i2: 3 unreachable empties are not free), `tests/test_neu4_cancel.py`.

## Live-Erwartung
1. i1 status shows 'wood 0 usable of 204' (or similar) while logs lie on unwalkable tiles; kern.log 'DF cancels ... Needs logs' says 'N without, M on another group'.
2. i2 shows 'containers X usable of Y empty' where the old census said 7 free; NOT promised: the 7 phantom barrels stay counted free by the census (no exclusion explains them yet) - the item sample (BUG-843) and DF's reason (BUG-841/844) handle them.
