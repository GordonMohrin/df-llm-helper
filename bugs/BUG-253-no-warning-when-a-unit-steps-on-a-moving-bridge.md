# BUG-253 No warning when a unit stepped onto a bridge while it moved
Status: fixed (offline, live-untested)
Severity: medium (the crush showed only as a death; the moment before it left no event)
Found: 2026-10-29, Run 15b Earthboat (y374 summer d74), fix6-crush
Module: `lua/dfllm/gate.lua` (`M.crush_risk`, `control`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
gate notes every unit near a moving bridge in its move record (BRIDGE_CRUSH matches a later death against it) and logs 'moving
with' only for the units seen when the move starts. A unit that walked onto the footprint during the move produced nothing until
it died (BRIDGE_CRUSH 475 ticks after 'B1 moving').

## Fix
New event GATE_CRUSH_RISK (B, gate): a unit on the footprint of a bridge that is moving now, once per move record, with the
bridge, the unit, its kind, the direction, our pull tick and the tile; kern.log warn. The death stays BRIDGE_CRUSH (A).
Contracts: EVENT GATE_CRUSH_RISK (schema.py, contract.lua); appendix regenerated.

## Tests
`tests/lua/test_gate_crush.lua` `BUG-253: ...` (fails on 2b9c009), `tests/test_fix6_crush.py` (contract).

## Live check
`dfllm events --type GATE_CRUSH_RISK` after a lowering at a busy B1; compare its tick with a later BRIDGE_CRUSH of the same unit
(the gap shows how late the crush is detected).
