# BUG-183 The 'EngraveSlab ... removed' warn is written on every economy pass
Status: fixed (offline, live-untested)
Severity: low (log noise: 35 identical warn lines since the reload)
Found: 2026-10-29, live test round 2 instance i4 (NEW8; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (the slab pass)

## Actual
The K.log warn ran on every removal; only the ORDER_STUCK emit went through `CAD.due` (`p.slab_ann`). autoslab re-queued the order each time, so
the warn repeated about every 30k ticks while the ghost waited.

## Fix
- The warn goes out only when the ORDER_STUCK cadence is due; the removals in between are logged at `debug` and counted (`p.slab_quiet`); the next warn adds `N more removed since the last warn`.

## Tests
`tests/lua/test_economy_b2.lua`: four passes with a re-queued order: one warn, the rest debug, one ORDER_STUCK (fails on b805745).

## Live check
In a fort with a ghost and no blank slab (autoslab on): kern.log has one `EngraveSlab: ... removed` warn per cadence episode, not one per economy pass.
