# BUG-443 The aqshaft ring on a heavy level hangs for a year in a soil fort, no boulders, no PROJECT_BLOCKED
Status: fixed (offline, live-untested)
Severity: high (i3 Castletongs: the shaft S2 stood at 60 % from z113 on; 74 of 181 orders stuck)
Found: 2026-11-05, Run 16c i3 Castletongs R6 (`runs/run-16c/FR-BUGS.md`): very deep soil, no boulders, no blocks; kern.log `c1a1aa84...: z113 is a heavy aquifer level: its 4 side tiles are walled from above` and then silence
Module: `lua/dfllm/aqshaft.lua` (`plug_missing`, `A.ring_step`, `A.where`), `lua/dfllm/economy.lua` (`M.wall_stock`), `lua/dfllm/runner.lua` (`Q.aqx`: `wall_stock`, `need`)

## Actual
The ring's wall material was checked by `economy.mat_for('wall', n)`, which answers yes for ONE log or boulder (the mood reserve held the fort's 5 boulders and the logs), so the ring started; the walls
needed blocks nobody could make, and the silent branches of `ring_step` (a hidden ring tile, a wall nobody builds) left no event.

## Root cause
`lua/dfllm/aqshaft.lua plug_missing` (mat_for ignores n); `ring_step` returns 'done' silently while a piece waits; the aqshaft never registered its walls as a rock need, so `economy.rock_dig` (stone dig request) and
`supply_wants` (caravans: `stone`) saw nothing.

## Fix
- `economy.wall_stock(K)` = {have, blocks, rock (free boulders after the moods' floor), logs, soil}; the aqshaft asks it for the ring (plug 2 + ring 4), before an open ring tile is walled and for the soil seal's walls:
  fewer than needed -> PROJECT_BLOCKED (A) `why=aq_stall:no_boulders` with the commands (`trade.want add stone,block`, `plan propose` for the stone dig to hard stone (BUG-438), `inspect workload`), the row says `stall zN: ...`, nothing is channelled blind.
- Every such check registers the walls as a rock need (`economy.need('rock', n, 'aqshaft <id>')`): `rock_dig` asks PROJECT_REQUEST bedrooms why=rock (the stone dig), a soil fort asks the caravans for stone (`supply_wants`).
- A ring whose pieces did not change state for `aqshaft.CFG.stall` (3 days) says `aq_stall:ring_stuck` once (the waits below were silent).

## Tests
`tests/lua/test_bug443_444_ring_stall.lua` (no_boulders then the ring starts, ring_stuck), `tests/lua/test_economy_pieces.lua` (wall_stock).

## Live check
A soil fort with 0 free boulders and a heavy level known: PROJECT_BLOCKED `aq_stall:no_boulders`, `need rock 6 (aqshaft ...)` in kern.log, trade.want shows stone; the ring starts when stone comes.
Open: logs count as wall material (buildingplan builds them); a fort whose only stock is the mood reserve keeps waiting until stone arrives. The exact silent branch of the live hang (hidden tile or missing blocks) was not provable from the logs: both now speak.
