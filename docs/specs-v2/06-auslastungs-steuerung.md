# Spec 06: Utilization Control (`python -m df_llm_helper workload`)

Priority: P1 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-06), not yet live-tested | Framework: see README.md

## Goal and Benefit
Automatically translate a high idle rate (Run 5: 60–76 % at pop 150) into the right measure. Causes occurred repeatedly: dig queue empty, only 11 picks, material (wood/coke) missing, stockpiles full, smoothing stock empty.
**Expected gain:** 2–3 orchestrator turns per cycle, idle permanently more stable (the player's request: "keep an eye on things like this" (translated)).

## As-Is State
`wirtschaft.flag`/`claude/auslastung` report idle < 50 %; the digest shows "Idle %". The orchestrator determines the measures with agents: `claude/raster`, `claude/kohle`, `orders.lua`, construction.

## Diagnosis (decision tree, one snapshot)
1. `jobs.open` high, idle high → jobs not executable: pick carriers (`work_weapons` vs. miners), suspended jobs, `Inappropriate dig square`, `Needs refined coal`, `Could not find path`.
2. `jobs.open ≈ 0` → no work: dig queue < 100? Stockpiles full? Standing orders capped?
3. Result: ordered list `cause → measure (command)` with estimated effect.

## Measures
- **Automatic (maintenance):** `claude/raster start`, `claude/kohle start`, restart `arbeit/orders`, raise filler orders smoothing/engraving.
- **Proposal:** `pickfix --apply`, trade list (wood, coke, picks), new dig stages (exploration), community buildings, more workshops.
- The effect is measured after `measure_after_s` (idle before/after) and stored in the KB.

## Configuration
`workload: {idle_warn: 40, idle_crit: 60, min_dig_queue: 100, measure_after_s: 300}`

## Fair Play
Only orders, labors, work groups, standing orders.

## Acceptance Criteria
1. Scenario "dig queue 0, idle 68 %": measure "new dig stage" first.
2. Scenario "208 open jobs, 54 idle, 11 picks": measure "picks/fuel".
3. Scenario "coke 0 + wood 0": reference to Spec 07.
4. The effect appears in the next digest as `ok erledigt` (done) or `ohne Wirkung` (no effect).
5. No repetition of the same measure within 10 min.

## Fixtures/Tests
`auslastung.csv`, `claude/status` with idle values, gamelog cancellation patterns.
