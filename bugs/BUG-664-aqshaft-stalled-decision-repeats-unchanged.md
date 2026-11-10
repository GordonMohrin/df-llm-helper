# BUG-664 The same aqshaft `stalled` PROJECT_BLOCKED and `project_released` DECISION every 60 days
Status: fixed (offline, live-untested)
Severity: low (noise)
Found: 2026-11-10, Run 16a i1 Basementflew y455-y463: 83 `project_released` decisions (events.jsonl:17717-17802) and a `stalled` PROJECT_BLOCKED for the same two shafts (y455s1b0, c1a1c221...) with the same cause `z125 dig, ring new/new/new/new; stall z125: the ring has not moved`, only the day count changed (2374 d, 2435 d, 2497 d); the shafts ended `parked breach:heavy_aquifer`
Module: `lua/dfllm/runner.lua` (`Q.stall_scan`, `Q.release_scan`, `Q.aq_repeat`), `lua/dfllm/aqshaft.lua` (`A.stall_key`)

## Actual
`stall_scan` and `release_scan` repeat every `stall_every` (60 d) while the shaft stays stalled; the text carries the day count, so the player sees "news" that is none.

## Fix
`Q.aq_repeat`: for an aqshaft both announcements use the cadence record (`R.skc`, `R.rlc`): ids = project:stage, tokens = the project's block and the level's stall why (`A.stall_key`). An unchanged cause is not announced again; a changed one (another stall why, a block) is, after `stall_every` as before. A parked project (`halted`) never was announced by these scans; its one `park` event stays (`Q.park_event`).

## Tests
`tests/lua/test_bug443_444_ring_stall.lua` and `tests/lua/test_bug529_slot_release.lua` adapted (once, then again when the cause changes).

## Live check
A stalled shaft: one `stalled` and one `project_released` per cause. Open: other templates keep the periodic repeat.
