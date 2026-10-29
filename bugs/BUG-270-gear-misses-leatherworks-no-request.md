# BUG-270 Gear 'body 0/5 no bars/leatherworks': no workshop requested
Status: fixed (offline, live-untested)
Severity: medium (5 soldiers without body armor or quivers for the run)
Found: 2026-10-29, Run 15 Earthboat (FR-BUGS.md), fix6-econ-supply
Module: `lua/dfllm/economy.lua` (`plan_gear`, `M.ws_ask`), `dfpilot/wake.py`

## Actual
kern.log 'gear: 5 soldiers ... body 0/5 no bars/leatherworks, quiver 3/5 no leatherworks'. plan_gear named the missing shop in the
route and emitted nothing.

## Fix
A gear slot without a route because no Leatherworks stands asks for it, and for the Tanners when none stands, together with a
Mechanic's workshop the levers need (BUG-268): one PROJECT_REQUEST workshops why=gear d.types (cadence of `M.ws_ask`, cleared when
nothing is missing); follow places only those types.

## Tests
`tests/lua/test_economy_supply6.lua` BUG-270, `tests/test_bug267_271_supply.py` (why=gear) (fail on 2b9c009).

## Live check
Earthboat: `dfllm events --type PROJECT_REQUEST` why=gear types [Leatherworks, Tanners]; cli.log `auto:gear`; once built the gear
line reads 'body 0/5 leather' or 'ordered'.
