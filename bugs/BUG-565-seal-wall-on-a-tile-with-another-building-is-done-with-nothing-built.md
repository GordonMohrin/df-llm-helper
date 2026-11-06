# BUG-565 A seal wall on a tile that holds a hatch is "done" at 100 % with nothing built and no reason
Status: fixed (offline, live-untested)
Severity: medium (the bypass the seal was placed for stays; nobody is told why)
Found: 2026-11-06, Run 16c i3 Sealcertain y405 (`runs/run-16c/FR-BUGS.md` "OBS Runde 13 y405: Bypass-Idee seal close=wall hinter der Treppenluke wirkt nicht"; `E:/DF-test3/dfllm-runtime/r16c4-sealcertain-site97/` cli.log + kern.log + events.jsonl read only, project c1a1af372f2465d901)
Module: `lua/dfllm/runner.lua` (`pre_occupied`, new `Q.seal_mismatch`, `measure_build`, `blocked_event`)

## Actual
`bp.place tpl=seal site=S1 at=55,132,137 close=wall` (the tile behind the hatch 54,132,137): preview a wall, `ok queued`; kern.log: `seal.build: quickfort orders created no manager orders`, `seal first: ... led 13 days without closing a piece (0 pieces open)`, SEAL_STUCK `built nothing for 0 days ... 0 pieces open`, then PROJECT_STAGE 100 % and PROJECT_DONE. The audit still said `bypass: via door 54,132,137 -> 55,132,137`.

## Root cause
`runner.lua` `pre_occupied` (live L2: a stage placed again over buildings it already has): a cell whose tile already holds a building gets no order (`occupied_cell`) and the building is adopted as the project's own piece ("tracked like ours", `R.b`). For a seal wall (`Cw`) on a tile that holds a hatch, door or trap that is wrong: the building is not a wall, `measure_build` read it as built and finished the stage with `done = 1`, `pend = 0`. Nothing says the tile was never walled.

## Fix
`Q.seal_mismatch(P, key, building, snapshot char)`: for a seal, what its key wants (`Cw` a Construction, `d` a Door, `H` a Hatch) against what stands on the tile. A mismatch is not adopted; it is named in `R.occ` (`Door 55,132,137 (a wall wanted)`). `measure_build`: a seal with `R.occ` and nothing built or pending is blocked `occupied` (never `done`; kern.log `nothing built: ...; the project is blocked`; `Q.FINAL`, so the park rule applies; PROJECT_BLOCKED names the building, the tile and the `bp.cancel` command, `d.parts`). A seal with other pieces that stand finishes as before and kern.log names the tile that holds another building.

## Tests
`tests/lua/test_bug565_seal_on_a_building.lua` (2): the wall on a hatch tile is blocked `occupied`, no PROJECT_DONE, kern.log and PROJECT_BLOCKED name `Door 55,132,137` and `bp.cancel` (old: done); a plain wall is still built and done; a two-piece seal with one occupied tile finishes and logs the other.

## Live check
Place a wall on a tile with a hatch or door: the project row says `blocked: occupied` after the next run, PROJECT_BLOCKED (A) after two days with the tile; cancel it.
Open: the CLI (`bp.place`) still accepts the wall when its snapshot predates the hatch; the reason comes from the kernel.
