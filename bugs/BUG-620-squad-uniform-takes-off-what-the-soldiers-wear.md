# BUG-620 `squad.uniform` replaced every spec of every position and lowered the worn percentage (43 -> 11 %)
Status: fixed (offline, live-untested)
Severity: medium (a verb that made the army worse)
Found: 2026-11-09, Run 16a i1 Basementflew y449 (`squad.uniform` melee on A, B, C: inspect military before A fit 2 / weapon 2 / armor 2, B 0, C weapon 2; ten minutes later all fit 0; brief worn 43 % -> 11 %, metal 0 %)
Module: `lua/dfllm/military.lua` (`verbs['squad.uniform']`, `filled_cats`)

## Actual
`squad.uniform squad=A kind=melee` was answered `melee uniform on 10 positions` and the soldiers lost what they wore. (A note of the same session: worn also swings without the verb, kern.log `uniform-unstick ... 44 % -> 15 % -> 46 % -> 7 % -> 30 %`; the verb's share of the drop is not certain.)

## Root cause
The verb gave `act.squad_uniform` the whole template for all ten positions in `mode replace`: every spec of those categories is cleared (the assigned items leave the position, `act.lua` squad_uniform) and rebuilt with the metal material class (`with_mats`, `best_mats` of the whole squad), whether a soldier wore the old spec's item or not. The new specs had to be fetched again, and the metal class could be one the fort cannot fill (`metal 0 %`).

## Fix
Per position and category: a spec the soldier wears now (`filled_cats`: `spec.item` or one of `spec.assigned` in the unit's Worn / Weapon / Strapped inventory, as `uniform_counts` counts it) stays untouched; only the unfilled categories and the vacant positions are re-specced, in groups of equal categories (one `act.squad_uniform` per group, `spec.positions` and the group's items). The materials come from `best_mats` of the number of positions to fill (free stock only: a worn piece is not stock). The answer says `squad A: melee uniform on N positions; kept K worn specs on M positions (...)`. A squad that wears everything it has a spec for is not touched at all. The weapon guard (`nw_set`) marks only the positions whose weapon spec was not kept.
- Expected effect: worn % is not lowered by the verb (the soldiers keep what they wear); unfilled slots get the best material the free stock can fill (leather or any when metal is short) instead of metal that is not there.

## Tests
`tests/lua/test_fr100_kit.lua` (position 0 wears everything: its specs are the same objects after the verb, no uniform call names position 0; position 1, nothing worn, is re-specced; a vacant position gets the template; the training policy ends; fails on the old code: `melee uniform on nil positions`).

## Live check
`squad.uniform squad=A kind=melee` with soldiers in armor: the answer's `kept K worn specs`, `inspect what=military` fit / armor unchanged or higher a few minutes later, brief worn % not lower.
