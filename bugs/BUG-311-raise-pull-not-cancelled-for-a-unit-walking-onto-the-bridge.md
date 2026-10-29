# BUG-311 A raise pull was not cancelled for a unit walking toward the bridge
Status: fixed (offline, live-untested)
Severity: high (a soldier crushed by B2)
Found: 2026-10-29, Run 15b Earthboat (y376 summer, RECOVERY after BREACH #2141), fix11-gate-crush
Module: `lua/dfllm/gate.lua` (`control`, `M.approach`)

## Actual
B2 up waited 5752 ticks for units beside it, was pulled at 151788921 the moment the 1-tile margin was clear, taken 14 ticks later,
`B2 moving up with citizen 26273 next to it` at 151789039, and #2182 soldier 26588 (squad 100 on his way to his station 55,80,135,
the route over B2) died `last seen on it at 57,82,138`. Not a forced raise (RECOVERY). Root cause: the BUG-251 cancel of a taken
pull when a unit within MARGIN_DOWN (3) tiles walks toward the footprint ran only for lowerings (gate.lua:1774 on 9ef2ccb,
`elseif dir == 'down' and w0`); a raise in a busy corridor went on while he walked onto it.

## Fix
The approach cancel applies to taken raise pulls too (not to a forced one: BUG-310's rule holds there); kern.log
`gate: <B> up pull cancelled: <unit> <d> tiles from it and walking toward it`. The quiet window before queueing stays a lowering rule.

## Tests
`tests/lua/test_gate_crush.lua` `BUG-311: ...` (fails on 9ef2ccb).

## Live check
kern.log `up pull cancelled ... walking toward it` at a busy B2 after a siege; no BRIDGE_CRUSH `to up` outside a forced raise.
Watch for raises delayed by a stream of walkers (GATE_FAIL slow/timeout of an inner bridge in PEACE/RECOVERY).
