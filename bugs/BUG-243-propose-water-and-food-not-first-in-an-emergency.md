# BUG-243 plan propose puts the cistern behind the phase builds while drink is at 0 days; no farm in the draft
Status: fixed (offline, live-untested)
Severity: high (G3/G4: the fort stays without water and food for seasons while the draft builds other rooms first)
Found: 2026-10-29, Run 15 Drillchamber y373 spr d75, Inkintense y372-y374 (FR-BUGS.md)
Module: `dfpilot/plan.py` (`propose`, new `emergency`, `emergency_drafts`, `fort_facts.food_shops`)

## Actual
Drillchamber: drink 0 d, no accepted water, the hospital held back (BUG-034); the cistern that replaced it was appended in phase
order and landed in seasons[2]. The player moved it by hand. Inkintense: food 10 d, the draft held no farm, kitchen or food store.

## Fix
`emergency(state)` names why water and food come first: `stock.drink_d` or `stock.food_d` below `EMERGENCY_D` (30), or a state
water key with no accepted source (`water.src` empty). `emergency_drafts` drafts what is missing: a cistern (`_cistern_due`), else
the aquifer well template `aqwell` when the bp package lists it (feature check for fix6-water); farms while food or drink is low
(unless applied before); a workshops build with only the missing Still/Kitchen (`fort_facts` `food_shops` from the manifest; p
add + skip of every moodable type, so the runner sees a supply build). These and the phase builds of the same kind go right after
the seals and the refuge's pieces (stage3_gate and refuge_gate still see those first), so they land in the current season. The
notes say "BUG-243: drink 0 d, food 10 d (< 30): cistern, farms, workshops@S1 first". In the BUG-197 year-1 branch (no fortcore
and no Z4 floor) rooms cannot be sited, so they are not drafted there; the note says to propose again after s1.dig.

## Tests
`tests/test_bug241_244_plan_propose.py`: `test_emergency_names_why`, `test_propose_puts_water_and_food_first_when_drink_is_out`,
`test_emergency_cistern_moves_ahead_of_the_phase_builds`, `test_no_z4_yet_notes_the_emergency_builds_for_after_s1_dig`
(fail on 6dc0f19).

## Live check
In a fort with drink below 30 days (brief `drink Nd`) or `status` src 0: `dfllm plan propose` shows `cistern@S1` (or `aqwell`),
`farms@S1` and a workshops build in the current season right after the seal/refuge builds; `plan check` passes them.
