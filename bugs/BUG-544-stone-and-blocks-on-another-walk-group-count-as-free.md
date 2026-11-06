# BUG-544 Boulders and blocks that lie on another walk group count as free stone: masons never work, the aqshaft ring never switches to logs
Status: fixed (offline, live-untested)
Severity: high (an aqshaft ring hung 600 days at a heavy aquifer level beside 255 logs; 88 rock orders stuck)
Found: 2026-11-06, Run 16a i1 Basementflew y414/y415 (`runs/run-16a/FR-BUGS.md` lines 299-305; `E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/dfllm-runtime/r16a5-basementflew-site97/` kern.log read only: "order 765 ConstructDoor x1: "Needs non-economic hard stone boulders", 0 free stone for 39 in rock orders")
Module: `lua/dfllm/economy.lua` (`classify`, `publish`, `M.bm_route`, `stone_free`)

## Actual
census rock 32 / boulders 64 / blocks 62 / stock.rock 19 "free", but every boulder and block lies in the flooded z117 complex (400 `~` tiles in the snapshot): masons (3 shops / 12 jobs / 0 working) and mechanics (2 / 2 / 0) never work, DF cancels "Make rock blocks/mechanisms: Needs non-economic hard stone boulders" in a loop. `economy.bm_route` took `inv.blocks_free` 13 as the wall material of the aqshaft ring, so buildingplan's `logs` setting was never switched on: the ring at z124 "waiting for materials" for 600 days beside 255 logs. The mood reserve held "boulders 0/6" beside rock 32.

## Root cause
`economy.lua` `classify` (the BOULDER branch and the PIECE_INV branch) counted every boulder, block, door, hatch cover, grate, chair and table that is not forbidden or built in. Only the *food* branches asked `a.far` (the citizens' walk group, `snapshot.far`), and `reach_mark` only records that ONE reachable item exists; `stone_free`, `wall_stock` and `bm_route` never looked at reach. So the unreachable stone was "free" for every consumer.

## Fix
`classify` asks `a.far(it)` for BOULDER and the PIECE_INV kinds: a boulder on another walk group is counted in `rock_far` (not in `rock`, `ore`, `flux`, `rock_bad`), a piece in `doors_far`, `hatches_far`, `grates_far`, `blocks_far`, `chairs_far`, `tables_far` (not in `doors` ... `blocks_free`). `boulders` stays the whole vector. So `stone_free`, `wall_stock` (`have` = blocks + rock + logs) and `bm_route` see only what citizens can carry: with the blocks and boulders out of reach `bm_route` answers the logs setting and `buildingplan set logs true` goes out; the MATERIAL_SHORT reason names the far stone ("(77 boulders and blocks lie on another walk group)"). No extra flag read per item (the census reads one flag word, test_kern_load).

## Tests
`tests/lua/test_bug544_547_stone_manager.lua`: the census counts near and far apart; the Basementflew case (64 far boulders, 13 far blocks, 255 logs, logs off) switches logs on and `wall_stock` counts logs only, reachable blocks switch nothing, nothing reachable names the other walk group.

## Live check
`inspect census` shows `rock_far` / `blocks_far`; with stone behind water the aqshaft ring wall project gets `buildingplan set logs true` in kern.log; masons stop being queued rock orders for stone nobody reaches.
Open: whether buildingplan itself still picks an unreachable block first when both settings are on (DF's job takes only reachable items, so the ring should build from logs); a boulder carried by a hauler on another walk group counts as far.
