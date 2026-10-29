# BUG-182 A standing ConstructSlab order nobody can work hides the 'no Masons' reason
Status: fixed (offline, live-untested)
Severity: low (the reason never reached kern.log or `inspect orders`)
Found: 2026-10-29, live test round 2 instance i4 (BUG-133d part 2; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (the slab pass)

## Actual
`sb.why = 'no Masons'` was set only inside `if n > 0`. Order 55 (ConstructSlab, left 1, no workshop) made `n = 0`, so no
`slabs: no ConstructSlab ... no Masons` line came although no mason's workshop stood.

## Fix
- `sb.why = 'no Masons'` also when `n <= 0`, ghosts still want a blank slab (`gneed > 0`) and no mason's workshop stands.

## Tests
`tests/lua/test_economy_b2.lua`: a standing ConstructSlab order, 1 ghost, no Masons: no new order, `inspect orders` slabs.why `no Masons` and the kern.log line (fails on b805745).

## Live check
In i4 with order 55 standing and no Masons: kern.log `slabs: no ConstructSlab for 1 ghosts (...): no Masons` once; `dfllm cmd inspect '{"what":"orders"}'` slabs.why `no Masons`.
