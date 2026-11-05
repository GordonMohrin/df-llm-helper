# BUG-505 The remaining wall builders (runner.repair) skip the BUG-487 reach check
Status: fixed (offline, live-untested)
Severity: critical (a wall can lock citizens, a farm, a well or a depot out: BUG-487 killed 12 that way through the plan build)
Found: 2026-11-05, verifier notes of BUG-487 (round 30 review): "weitere Wandbauer ohne Reach-Check: seal.lua 1883 KP.extend (Rampenkopf), 1935 KP.close, 2044, 2118 via runner.repair"
Module: `lua/dfllm/runner.lua` (`M.repair`), `lua/dfllm/seal.lua` (plug calls)

## Actual
`bp.place` (BUG-458) and the plan build (BUG-487) ask `seal.wall_cuts` before a `Cw` wall goes in. `runner.repair` did not: seal.lua queues walls through it in `KP.extend` (the extra closure stage beside a bridge closure, ramp-top walls), `KP.close` (wall + door that replaces a lost bridge), the lost-bridge repair and the perimeter repair after a siege.

## Fix
`M.repair` runs `Q.place_walls(K, d, 'repair')` on its document before `register`: where it refuses (cut, partial or unknown reach; in a siege only on a proven cut, as for `bp.place`) the walls become doors (`Q.walls_to_doors`, kern.log `repair rpN: ... its walls are built as doors (BUG-505)`, WALL_REFUSED how `repair` so the plan layer knows the tile). A closure (`opts.closure`: walls + door replace a bridge) and a wall on a ramp top cannot be a door: `repair` returns `false, reason` and the callers log / wait as for any refused repair. `opts.noreach` skips the check: the BUG-479 refuge plug confines on purpose (both plug calls in seal.lua pass it). Doors, chairs and other cells are not asked.

## Tests
`tests/lua/test_bug503_505_sealreach.lua` (4: a cutting wall becomes a door with WALL_REFUSED, no cut keeps the wall and a door cell is not asked, a cutting closure is refused with the reason, unknown reach is a door, `noreach` is not asked). The whole Lua suite incl. test_bug479_refuge_plug, test_bug487_plan_seal_walls, test_bug458_wall_reach stays green.

## Live check
A repair whose wall would cut: kern.log `wall refused (repair): would cut N off ...` and `repair rpN: ... built as doors`; `dfllm events` WALL_REFUSED. A bridge closure that cuts: seal.lua logs `wall + door not queued: refused: ...` and retries.
Open: a lost-bridge closure that would cut is retried until `gq_keep` and then given up; deciding such a bridge by hand stays the player's.
