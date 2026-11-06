# BUG-535 A strange mood says "gems none in the fort [0/0/0]" while the census holds 39 gems
Status: fixed (offline, live-untested) as a diagnosis; the cause below is the reading that fits the logs, the mood job itself was not captured
Severity: medium (the player cannot tell a missing rough gem from a missing cut one; the route was wrong)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y389 (`runs/run-16d/FR-BUGS.md` "Mood-Kind (Secretive/Fey) ohne bone/gems"; events.jsonl #6290-#6311 MOOD_NEED / MOOD_CRITICAL / DECISION_NEEDED mood_material, read only)
Module: `lua/dfllm/care.lua` (`need_item`, `mood_report`, `slot_text`), `lua/dfllm/reserve.lua` (`R.slot_name`, `R.acq`, `R.gem_forms`)

## Actual
`inspect` said 39 gems in the fort; the child's mood reported `gems x1: none in the fort [0/0/0]; bone x1: none in the fort [0/0/0]; gems x1: enough exist` and `acq gems:order:CutGems+buy`. Two filters of the same mood were fine, one was "none" with `kind` 0 (not even an item of its vector).

## Root cause
The census (`economy.lua:1037-1043`) counts cut gems (SMALLGEM) and rough inorganic gems (ROUGH) together as `gems`. The mood has one filter per form (`reserve.lua:140-141`: SMALLGEM and ROUGH, each its own vector); the fort had cut all its rough gems (CutGems), so the ROUGH filter saw an empty vector while the other two took cut gems. The report named all three `gems`, never the form, so 39 gems beside "none in the fort" read as a bug; and the acquisition list offered `order:CutGems` for it (`reserve.lua:43`), which only turns the rough gems that are left into cut ones. Second blind spot: `need_item` returned before counting an item `R.carried` (worn, or in a claimed bin), so such gems were invisible in every number (`care.lua:3460`).

## Fix
The slot says its form (`gems(rough)` / `gems(cut)`, `R.slot_name`) and, when the other form exists, how many (`..., 3 cut gems exist, a rough one is needed` / `2 rough gems exist, a jeweler cuts them`; `R.gem_forms` reads the two vectors once per mood). A rough-gem slot's acquisition is `buy` only (`R.acq`; MOOD_NEED `acq`, `mood_wants` `acq`). Carried or claimed-bin items that match the filter are counted: `, N carried/in a claimed bin`.

## Tests
`tests/lua/test_bug535_gem_forms.lua` (3).

## Live check
A mood with a rough-gem filter in a fort with cut gems only: MOOD_RISK / MOOD_NEED show `gems(rough) x1: none in the fort [0/0/0, N cut gems exist, a rough one is needed]` and `acq gems:buy`.
Open: whether the live mood's missing slot was really the ROUGH filter is inferred (vector empty, the other two slots fine, no `of N`); the mood job was gone when the logs were read. Nothing keeps rough gems back from the CutGems order for a mood that wants one (the reserve holds `gems` 5/5 of either form).
