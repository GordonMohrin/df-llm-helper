# BUG-829 the growth gate's failing step was inferable only from scattered sources; "drink inside the core ? d" for a fort without drink
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-24, Run 17 i3: the squad size (A 2), the weapon census (g_weapon 0) and the wooden-backed rule had to be pieced together from kern.log, cli.log and state
Found (2): Run 17 i2 Whirledrampart y482: ready.gh halt 'drink', need 'drink inside the core ? d < 30 d': seal's `alert.core_d` was nil because `supply_check` set `days = nil` when the fort holds no drink at all (total 0), although economy's `stock.drink_d` reads 0 (`dwhy` '6 brews ordered, none ran for 508 days ... empty barrels'). The '?' hid a real shortage: i2 sits at 30 for want of drink (brewing broken), not for the squad step.
Module: `lua/dfllm/seal.lua` (`supply_check`), `lua/dfllm/military.lua` (`mil.kit` in the state frame), `lua/dfllm/util/contract.lua` and `dfpilot/schema.py` (optional keys)

## Fix
state `mil.kit` gains optional `sq` (members of the first melee squad), `sqw` (of them armed: real weapon in hand or backed) and `wb` (wooden hands counted armed by a real weapon waiting): exactly the numbers readiness.growth_ladder reads. Contract and schema (CONTRACTS appendix) in sync.

## Fix (2)
`supply_check` (seal.lua): a known stock day count with no drink units in the fort is 0 days inside, so `alert.core_d` = 0 and the ladder text reads "drink inside the core 0 d < 30 d". Nothing else changes (the cap stays held: the fort has no drink).

## Tests
`tests/lua/test_bug827_first_squad_seats.lua` (BUG-829 case), `tests/lua/test_stranded.lua` (core_d 0 without drink); schema roundtrip by the existing contract tests.

## Live-Erwartung
1. `state.a.json` of every fort shows `mil.kit.sq`/`sqw`/`wb`; when `ready.gh.halt` is "squad", `need` reads "first squad: <sqw> of <sq> ..." with the same numbers.
2. i2 (no drink, `stock.drink_d` 0): `alert.core_d` is 0 and `ready.gh.need` reads "drink inside the core 0 d < 30 d" (not "? d"). The halt itself stays until the brewing works (economy).
