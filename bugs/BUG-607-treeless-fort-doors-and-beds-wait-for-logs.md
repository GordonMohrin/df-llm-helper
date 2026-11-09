# BUG-607 Doors and beds wait for logs in a fort without trees
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-09, Run 16c i3 Wallfree y374-y376 (doors/beds 32+ days for logs, seal 66 %, bedrooms 43 %; only `trade.want wood`)
Module: `lua/dfllm/economy.lua` (`M.piece_route`, `M.treeless`, `T.days`, `T.jmake`, `M.supply_wants`), `config/baseline.json`

## Actual
Doors and beds wait for logs in a fort without trees.

## Root cause
The fort had no tree: logs 0 for a month. The doors, chests, tables and the like waited for wood; the stone route was shut by the hard-stone denial (`stock.rhard`, BUG-545: three DF cancels make `stone_free` 0), so `M.piece_route` answered `no material` for everything and a bed (wood only) said nothing about the trees.

## Fix
`economy.lua` `M.piece_route`: a fort with no log for `pieces.treeless_days` (20; `p.nowood` kept by `T.days`, or no tree on the map at all) is treeless; its doors, chests, tables ... go to the Masons even while the denial holds the stone at 0 (a probe on the boulders the census calls usable; the second denial episode, BUG-610, turns it off). A bed is wood only: the answer says `no logs, the fort has no trees` and `a bed is wood only: trade.want wood`; `T.jmake` counts such beds (`st.wood_short`) and `M.supply_wants` asks the caravans for logs (`wood`).

## Tests
`tests/lua/test_bug607_612_econ.lua` (treeless: stone door in the denial, bed named, a fort with logs unchanged)

## Live check
A treeless embark: `mat_for door` answers `rock`, MATERIAL_SHORT names `a bed is wood only: trade.want wood`, `trade.want` shows `wood` from `supply_wants`; if DF cancels the stone doors too, the probe ends with the second denial.
