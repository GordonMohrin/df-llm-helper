# BUG-085 The squad.add verb enlists any unit the game knows, not only the living adult citizens the squads screen lists
Status: fixed in the integration audit I4 commit (offline, live-untested): the verb refuses a unit that is not a living adult
citizen before it calls the game, with the same text `squad.leader` gives; the act and its other callers are unchanged
Severity: low (fair play: a verb that does more than the screen it stands for; no live harm seen)
Found: 2026-10-23, integration audit I4 of the first pass (BUG-055 merged with the military and fair-play rules)
Module: `lua/dfllm/military.lua` (`M.verbs['squad.add']`), `lua/dfllm/act.lua` (`I.squad_add`)

## Actual
`dfllm cmd squad.add {squad, unit}` checked the squad (it exists, it has a leader) and nothing about the unit: it called
`act.squad_add`, which is `dfhack.military.addToSquad(unit_id, squad_id, -1)`. That call takes any unit with a historical
figure: a visitor, a child, a dead citizen, an invader. The squads screen offers living adult citizens only (RULES 1.1: only
what a player can do through the UI). Its sibling verb `squad.leader` goes through `act.squad_leader`, which refuses
"not an adult living citizen"; `appoint` has the same check in its act.

## Cause
BUG-055 turned `act.squad_add` (until then called by military's own fill, which only picks citizens) into a verb whose
argument comes from the orchestrator. The verb handler did not take over the citizen test the other two verbs have.

## Fix
`M.verbs['squad.add']` looks the unit up and refuses a missing, dead, non-citizen or non-adult unit with
`unit N is not an adult living citizen`, before `act.squad_add`. military's own fill is unchanged.

## Tests
`tests/lua/test_integration_i4.lua` (fails on 9bcb14f): a visitor, a child citizen, a dead citizen and an unknown id are refused and
`squad_add` is never called; a citizen joins.
