# Spec 03: Mood Manager (`dfpilot mood`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-03), not yet live-tested | Framework: see README.md

## Goal and Benefit
Fulfill strange moods in time instead of risking berserkers. In Run 5, 6 of approx. 10 moods failed (Reg, Etur, Logem, Dastot; Stûkud and Åblel died of thirst). Causes: wood 0 (charcoal consumed the wood), unknown requirement `NONE`, rough gems tied up by CutGems jobs, missing cut stones, tight time limit (50 000 ticks correspond to only a few real minutes at 250 fps), thirst.
**Expected gain:** fewer deaths and berserker incidents, fewer diagnostic turns (5–10 calls per mood).

## As-Is State
`claude/mood status|plan|prebuild` and `mood.flag` report category and gaps, but decode the requirement imprecisely (`NONEx1`). The real requirement is in the running job: `unit.job.current_job.job_items.elements[]` (item_type, mat_type, mat_index, quantity, flags).

## Behavior
1. **Detect:** `mood.flag` or unit with `mood` not None/Insane.
2. **Read requirement:** via Lua (`pilot_mood.lua`) the job elements as a list `(item_type, material, quantity, flags)`; `NONE` is decoded via the `flags1/2/3` bits (e.g. not wood, bone, skin) and recorded in the KB.
3. **Check stock** (reachable = `canWalkBetween`, not trader/foreign/forbid/in_job): free quantity, location, path per element.
4. **Fix gaps** (maintenance only, no item manipulation):
   - Release rough gems/bars from CutGems/smithing jobs: remove direct jobs (`dfhack.job.removeJob`), pause the cutting order until the mood is over.
   - Wood missing: block charcoal starter and wood consumption, raise trade `wants` for wood, report.
   - Cut stones missing: trigger `cut gems` specifically.
5. **Time:** compute remaining ticks against travel time; if impossible, early warning "will fail" and berserker plan (civilians kill him; note).
6. **Aftercare:** artifact finished → delete `mood.flag`; failed → berserker report and raise reserve rules.
7. **Prevention:** from pop ≥ 20 check reserves: wood ≥ 10, cut stones ≥ 3, rough gems ≥ 4 + requirement, bone 5, leather 3, metal 3 (digest warning).

## Configuration
`mood: {reserves: {wood: 10, cut_gems: 3, rough_gems: 4, bone: 5}, release_cutgems: true, warn_timeout_ticks: 8000}`

## Fair Play
No item creation or moving. Removing jobs is a UI action. No dwarf manipulation.

## Acceptance Criteria
1. Test "rough gems 6, of which 4 in CutGems jobs, requirement 3": jobs are released, afterwards 3 free.
2. Test "wood 0": report and adjusted shopping list, no charcoal start.
3. Test "NONE element": is decoded or reported as `unbekannt`, never silently ignored (property test).
4. Test "timeout < travel time": warning "will fail".
5. Mood report ≤ 6 lines.

## Fixtures/Tests
`job_items` excerpts of the moods (Etur, Logem, Dastot, Åblel, Reg), `mood.log`, stock queries (`ROUGH`, `SMALLGEM`, `WOOD`).
