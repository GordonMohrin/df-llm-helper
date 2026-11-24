# BUG-829 the growth gate's failing step was inferable only from three scattered sources
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-24, Run 17 i3: the squad size (A 2), the weapon census (g_weapon 0) and the wooden-backed rule had to be pieced together from kern.log, cli.log and state
Module: `lua/dfllm/military.lua` (`mil.kit` in the state frame), `lua/dfllm/util/contract.lua` and `dfpilot/schema.py` (optional keys)

## Fix
state `mil.kit` gains optional `sq` (members of the first melee squad), `sqw` (of them armed: real weapon in hand or backed) and `wb` (wooden hands counted armed by a real weapon waiting): exactly the numbers readiness.growth_ladder reads. Contract and schema (CONTRACTS appendix) in sync.

## Tests
`tests/lua/test_bug827_first_squad_seats.lua` (BUG-829 case); schema roundtrip by the existing contract tests.

## Live-Erwartung
1. `state.a.json` of every fort shows `mil.kit.sq`/`sqw`/`wb`; when `ready.gh.halt` is "squad", `need` reads "first squad: <sqw> of <sq> ..." with the same numbers.
