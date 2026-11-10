# BUG-663 A new aqshaft after bp.cancel "inherits" the stall counter and the ring state
Status: not reproducible (state is per project id; regression test added)
Severity: low (report)
Found: 2026-11-10, Run 16b i2 Valleyhame y378: c1a1c4abe568 "no progress for 430 d" shortly after bp.place, ring z135 `new/new/new/new` as in the cancelled predecessors
Module: `lua/dfllm/aqshaft.lua` (`A.shaft`), `lua/dfllm/runner.lua` (`new_R`, `Q.stall_scan`)

## Actual (as reported) / found
kern.log (r16b5-valleyhame-site97): `queued c1a1c4abe568e79701` at tick 152,631,236; first `stalled: no progress for 60 d` at 152,724,081 (77 days later), then 120, 180, 244, 304, 368, **430 d** at 153,168,361: the "430 d" is the project's OWN age (queued 447 d earlier), not an inherited counter. The aqshaft record (`rt.aq[id]`), the runner record (`rt.p[id]`: `ps`, `sks`) and the level stall are keyed by the project id (`A.shaft` creates `levels = {}`, `new_R` sets `ps = now`). The ring state `new/new/new/new` on the same z135 is the same CAUSE three times (the ring never moved: `need rock`, hidden tile - BUG-631/632), not a copied state.

## Fix
None needed for inheritance. The repeated, unchanged stall announcement ("no progress for N d" every 60 d) is BUG-664. A regression test pins that a shaft placed after `bp.cancel` of a stalled one starts clean.

## Tests
`tests/lua/test_bug662_ring_wall.lua` (BUG-663: no stall inherited, own progress time, no `stalled` event at once).

## Live check
`bp.cancel` a stalled aqshaft, place a new one at the same column: its first `stalled` is `stall_days` after ITS placement. Related: BUG-664, BUG-631, BUG-632.
