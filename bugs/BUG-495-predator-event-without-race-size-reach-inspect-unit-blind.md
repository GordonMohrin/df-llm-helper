# BUG-495 PREDATOR / INTRUDER name no race, size or reach; `inspect what=unit` does not know non-citizens
Status: fixed (offline, live-untested)
Severity: medium (the player cannot judge a sortie from the event)
Found: 2026-11-05, Run 16c i3 Sealcertain y377 (FR-BUGS "PREDATOR-Event ohne Art/Groesse, inspect unit kennt Einheit nicht")
Module: `lua/dfllm/reflex.lua` (`unit_facts`, `inside_scan`), `lua/dfllm/sense.lua` (hostile entries `rn`, `rc`; `M.describe`), `lua/dfllm/curse.lua` (`inspect_unit`), `dfpilot/schema.py`

## Actual
`PREDATOR` data was `{n, id, pos}` and its text "N wild dangers inside the fort (id at x,y,z)": no species, no body size, nothing about reach. `dfllm cmd inspect what=unit key=<id>` answered "unit N is not a citizen or resident of the fort" for any wild unit, so the id in the event could not be looked up.

## Fix
- sense: every listed hostile carries `rn` (race name) and `rc` (reach: 1 on the citizens' walk group, 2 from a bank tile, 0 out of reach, nil unknown); `sense.describe(id)` answers for any unit (race, size cm3, wild/tame/invader/caged/merchant, large-predator flag, killer mark, building destroyer, danger, water at the tile, reach, distance to the nearest civilian, job).
- reflex: INTRUDER and PREDATOR add `race`, `sz`, `reach` and `cmd` (the exact `squad.sortie` for the unit's tile; not for a great danger or an undead) to their data and a bracket to the text ("[MAMMOTH, 4000000 cm3, reachable]").
- care's `inspect what=unit` for a non-citizen id asks sense.describe (the old answer stays when sense cannot read the unit). PREDATOR_FAR is unchanged.

## Tests
`tests/lua/test_reflex.lua` (+1: PREDATOR and INTRUDER facts and sortie), `tests/lua/test_bug494_water_beast.lua` (describe), `tests/test_bug494_496_wild_water.py` (schema), test_curse (the old answer without sense).

## Live check
A PREDATOR/INTRUDER line shows `[race, N cm3, reachable]`; `dfllm cmd inspect what=unit key=<d.id>` returns the sheet of the wild unit.
