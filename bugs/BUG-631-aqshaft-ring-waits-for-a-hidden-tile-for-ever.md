# BUG-631 The aqshaft ring stays new/new/new/new for ever: it waits for a tile only its own channel reveals
Status: fixed (offline, live-untested)
Severity: critical (blocks Gordon's wish "dig safely through the aquifer": i1 two sites at z125 for 900-1400 days, i2 z132 / z135 for 540 days)
Found: 2026-11-10, Run 16 round 19 (`runs/run-16a..16d/FR-BUGS.md`, round19_notes R1 / Y3 / V2): `stalled: no progress for 1393 d at l6.dig 30%: z125 dig, ring new/new/new/new; stall z125: the ring has not moved` (i1 `y455s1b0`, `c1a1c221c6a50a7601`, kern.log), i2 `y372s0b3` `z132 dig, ring new/new/new/new` (events.jsonl), miners idle with `no reachable work`
Module: `lua/dfllm/aqshaft.lua` (`A.ring_step`)

## Actual
The ring of a heavy level (BUG-414) has four pieces; each starts `new`, goes `chan` (channel designated on the dry level above) -> `open` -> `wall` -> `done`. In every live ring the four pieces stayed `new` from the first minute (the kern.log has `z125 is a heavy aquifer level: its 4 side tiles are walled from above` and then nothing: no `quickfort designated no channel`, no refusal, no yield warning). The player suspected `designate` yielding for ever.

## Root cause
`aqshaft.lua A.ring_step` (the loop over `R.pieces`, before this fix):
`local top, bot = X.tile(x, y, z + 1), X.tile(x, y, z); if not bot or not top then return 'done' end -- hidden: wait` ran BEFORE the `new` branch that designates the channel. `bot` is the ring tile on the heavy level z, diagonally below the open stair tile of z+1; `snapshot.tile` answers nil for a hidden tile (`snapshot.lua M.tile`: `des.hidden`), and (inferred: the live logs hold no tile dump) a dug tile reveals only its face neighbours. The tile stays hidden until the channel above it is dug, and the channel is designated only in the `new` branch behind that check: a deadlock, silent (`return 'done'`, no log, no event) -- the BUG-443 ring_stuck stall fired after 3 days with the bare `the ring has not moved`, and the runner then repeated it as DECISION_NEEDED. The channel itself needs only `top` (beside the dug stair, revealed by the dig; quickfort designates a channel on it whatever `bot` is), and `chan` -> `open` already waits for the ramp below `("the ramp below shows once it is revealed")`.
Not the cause: `designate` yielding (`X.room()` false) happens only when other quickfort calls fill the slice, and it would have been a `'yield'` result, not this state; the wall material (the `open` stage) was never reached in any of the logs (`ring new/new/new/new`).

## Fix
`ring_step`: the `new` branch needs only the tile ABOVE (`top`); a hidden ring tile is treated as "not walled, not open" and the channel is designated; `open` / `wall` still need the ring tile (named below). The tile read after the channel is dug (`chan` -> `open`) waits for the revealed ramp as before. Every silent wait now sets `R.wait` (the hidden channel tile with its x,y,z; the ring tile; the ramp below the dug channel; no quickfort call left in the slice) and the `ring_stuck` stall prints it (BUG-632).

## Tests
`tests/lua/test_bug631_ring_hidden.lua` (hidden ring tiles: the channel is designated and piece 1 leaves `new`, the wait for the hidden ramp is named, the ring goes on once it shows), `tests/lua/test_bug443_444_ring_stall.lua` (the stuck tests now hide the channel tile above).

## Live check
A heavy level known (`aquifer_levels` / hvl): kern.log `z.. is a heavy aquifer level: its 4 side tiles are walled from above`, then within a day `ring chan/new/new/new` in `inspect` (the `h` on z+1), a `Cw` wall on the ramp after the miner dug it. If the pieces still stay `new` the PROJECT_BLOCKED `aq_stall:ring_stuck` now says which tile is hidden or that no quickfort call was left.
Open: whether the wall material is reachable (`open` stage) was never seen in the live logs; BUG-632 names it.
