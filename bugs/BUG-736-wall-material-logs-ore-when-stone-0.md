# BUG-736 Wall material: a ring wall waits for stone beside 385 logs
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Doorwings y381/y382 (AQ_RING_STOP 'ring wall unbuilt for 32 d / 31 d' at z140, twice; census wood 385-440, MAGNETITE 25 ore, CHALK flux, blocks 132 but blocks_free 0, every ConstructBlocks order 'removed: no logs for it (426 logs)'; ghosts 27541 / 28225 'no ConstructSlab: 0 free boulders for 2 slabs')
Module: `lua/dfllm/economy.lua` (`wall_alt`, `wall_stock`, `bm_route`, `T.jmake`, `no_rock`, census), `lua/dfllm/aqshaft.lua` (ring stall), `lua/dfllm/runner.lua` (`wall_alt` hook), `lua/dfllm/act.lua` (`WOOD_JOBS`)

## Root cause
1. A wall (ring, plug, seal wall, depot) waits for whatever buildingplan hands it. The switch to logs (`T.jmake`, BUG-667: buildingplan boulders off) fired only when DF had REFUSED the stone (`stone_none`) and a planned building sat in the job scan; with boulders that were free by the census but reserved by the moods' floors (`stone_free` 0), ore / flux, or out of reach, buildingplan kept boulders ON and the wall waited (`economy.lua` `bm_route` deny line, `T.jmake`). The ring stage (`aqshaft.lua` ring branch `pc[3] == 'wall'`) only stalled and stopped after 30 d; it never changed the material.
2. `blocks_free` counts blocks not in a job and on the citizens' walk group (`economy.lua` census `M.PIECE_INV` branch). The 132 blocks were therefore held by jobs or out of reach; the census dropped them without a trace, the stall text showed a bare 0.
3. `no_rock` re-entered a rock order in wood only for the furniture jobs (`wood_orders.jobs`, `act.WOOD_JOBS`); ConstructBlocks was removed and the log line said 'no logs' with 426 logs.
4. Slabs: DF makes a slab of stone only (a wooden path does not exist); the text '0 free boulders for 2 slabs' did not say what the fort has.

## Fix
- `M.wall_alt(K)` (new, called by the ring stall after ring_wait through `X.wall_alt`): no free stone, no free block, logs above the floors: buildingplan boulders go off (`p.bpoff = 'wall'`) and logs on; no logs: ore / flux boulders are the wall material (boulders on). Returns the sentence the stall / AQ_RING_STOP text carries. `T.jmake`'s switch also fires when `stone_free` is 0 (`r.nostone`), and the boulders come back on only when 8 stones are free again or the logs are gone (no flapping).
- Water safety: the ring logic reads only the tile's construction state (`bot.c == 'C'`), never its material; a constructed wall of logs, blocks or ore stone stops water the same. Test: a wall tile 'C' ends the stage.
- `wall_stock` returns `alt` (ore + flux boulders), `busy` (`blocks_busy`, new census key: blocks a job holds) and `far` (`blocks_far`); `aqshaft.plug_missing` counts the ore / flux as possible and names busy / far blocks in the `no_boulders` text.
- `no_rock`: a rock ConstructBlocks order is re-entered in wood (`act.WOOD_JOBS` + economy), the log line names the true cause.
- Slab text: boulders free, ore, flux, refused, out of reach; 'a slab is stone only, logs make coffins for bodies a hauler reaches: trade.want stone or dig hard stone'.

## Tests
`tests/lua/test_bug736_wall_material.lua` (6: blocks_busy, wall_alt logs path and route, no switch when stone / blocks are free, ore / flux path, no flapping, ConstructBlocks to wood), `tests/lua/test_bug736_ring_alt.lua` (4: stall asks wall_alt and names the log wall, ore / flux possible, busy / far named, a wall of any material ends the ring stage).

## Open
Whether DF's own construction filter takes ore / flux boulders (the last resort, only without logs and blocks) and whether wooden blocks are a carpenter job in this DF build are not tested live; the ghosts with a body in a tree crown still need a stone slab (no wooden slab exists in DF).
