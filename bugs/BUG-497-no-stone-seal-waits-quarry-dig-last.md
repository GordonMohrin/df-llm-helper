# BUG-497 No stone in the fort: a seal door waits behind other owners' wood, the dig to hard stone sits behind the rooms
Status: fixed (offline, live-untested)
Severity: high (the way in stood open 30+ days, 15 of 29 adults idle, strange moods without stone)
Found: 2026-11-05, Run 16d i4 Trumpetrealms y384 (FR-BUGS "Fort ohne einen einzigen Stein": seal wall 112,13,141 open 30 d, mood 'boulders(hard) x1 none in the fort', 22 of 29 adults idle, 54 unclaimed jobs, the explore at 40 % 'set aside, no runner slot'), Run 16a i1 Basementflew (soil fort)
Module: `lua/dfllm/economy.lua` (`M.wood_left`, `scan_orders`, `M.stone_zero`), `lua/dfllm/runner.lua` (`sorted`, `Q.quarry_first`), `dfpilot/plan.py` (`stone_first`)

## Actual
- `economy.wood_left(c, r, def)` (a seal door, hatch, grate: `def`) subtracted every open order's wood (`s.used.wood`: other owners' barrels, beds, tables included) from the stock. i4 y384: 175-237 logs in stock, MATERIAL_SHORT 'stone queued for door: behind the other rock orders, no logs' again and again (events.jsonl n 1952..5658); kern.log: the door 112,13,141 'waits for door x1 (0 free, 4 ordered, 2 not validated)', replaced by a wall after 28 days, the wall 'no item' at 30/60/90 days. The code comment promised 'a seal door before a barrel'.
- The runner queue (`sorted`) knew seals, the hospital and the mood projects first; the explore that digs to hard stone queued with the rest (prio, then age), so with `active` 3 it stood behind bedrooms and a tavern (kern.log 'set aside, no runner slot').
- `plan propose` / follow drafted the stone quarry (BUG-430/438) wherever the left-out dig stood in the season, behind the other new builds.

## Fix
- `scan_orders` counts the wood of other owners' open orders separately (`s.xwood`); `wood_left` for a defense piece takes only the moods' floor, our own open orders and this run's plans off the logs (a door before the barrels).
- `economy.stone_zero()` (st.rock.free <= 0 after the stone census); the runner sets `S.stone0` each scheduling pass, `Q.quarry_first(P)`: an `explore` project sorts with the hospital and the mood projects (after the seals) while there is no free boulder.
- `plan.stone_first(save_dir, doc, prev)` (propose, follow, minimal plan): with state `stock.rock` 0 or the soil mark the NEW builds of a season are ordered seals, the digs that reach hard stone (explore, the bedrooms stone dig), the rest; applied builds keep their index (stable_ids); note 'BUG-497'.
- The wall itself already takes logs (`bm_route`, buildingplan logs switched on when only logs are there); nothing changed there. Why that wall still read 'no item' with logs in stock is not proven offline.

## Tests
`tests/lua/test_economy_pieces.lua` (the door in wood with 200 logs and 300 wanted by others; old code: no order), `tests/lua/test_bug497_500_material.lua` (2: the explore runs among the first three projects with no boulder, the order is unchanged with stone), `tests/test_bug497_500_f31.py` (4: order of the new builds, applied index kept, no stone no move, soil fort).

## Live check
kern.log shows the explore among the running projects while the census has no boulder; a seal door in a fort with logs and a long wood order list gets its `dfllm:piece_door` wood order at once; `plan propose` in a stone-0 fort lists seal, explore, then the rest and the notes say BUG-497.
