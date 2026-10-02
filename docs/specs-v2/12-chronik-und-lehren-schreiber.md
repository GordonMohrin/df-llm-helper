# Spec 12: Chronicle and Lessons Writer (`dfpilot journal`)

Priority: P2 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-12), not yet live-tested | Framework: see README.md

## Goal and Benefit
At the end of every session, chronicle, metrics and lessons should be produced automatically, so that no details are lost and no tokens are burned on summaries. On 01.10. alone, Run 5 had: 6 attacks, 6 failed moods, the water tunnel accident, the plump helmet conflict and the standing trader permission; much of it ended up by hand in memory and `ERFAHRUNGEN.md`.
**Expected gain:** approx. 10–20 calls per session, more complete postmortems.

## Behavior
1. **Event log** in `state.db`: structured entries per event (type: attack, mood, death, caravan, construction completion, emergency), date (game calendar), real time, participants, outcome, cost (turns/tokens), measure.
2. **Chronicle draft** for `chronik.md`: terse, German, date + fact (e.g. "J106 Granite 25: Goblin-Armee (15 + Drache) besiegt, 0 Verluste" (German; goblin army (15 + dragon) defeated, 0 losses)); shown for approval or `--append`.
3. **Lesson proposals** from recurring patterns (same cause ≥ 2×, e.g. "wood 0 → mood failed") as memory and KB entries; only with approval by the orchestrator.
4. **Metrics export** `metrics.csv`-compatible (pop, idle, food, drinks, guard, dead, open jobs) once per game month.
5. **Postmortem scaffold** (`journal postmortem`): timeline, causes of death, decisions with outcome, open questions, key figures, references to chronicle/KB.
6. **Exception register log:** every fair-play exception (e.g. `flags1.left`, `foreign=false`) with time, objects and quote.

## Configuration
`journal: {chronik: chronik.md, metrics: metrics.csv, append: false, suggest_after_repeats: 2}`

## Fair Play
Only reading and writing the own documentation; memory files only with approval.

## Acceptance Criteria
1. From `tools/events.log` and the digest history a chronicle draft is produced that covers all KRITISCH events of a sample session (recall ≥ 90 %).
2. A pattern (2× "mood fails, wood 0") produces exactly one lesson proposal, no duplicates.
3. `metrics.csv` export has the same header line as the existing file.
4. The postmortem scaffold contains timeline and causes of death, without inventions (only data from `state.db`).
5. No write accesses outside `dfpilot/` and the configured files.

## Fixtures/Tests
`tools/events.log` excerpt (Run 5), `chronik.md`, `metrics.csv`, sample events.
