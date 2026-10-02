# Spec v3-06: Remote-worker protection (`python -m df_llm_helper care remote`)

Priority: P1 | Date: 01.10.2026 (run 5, Y109) | Status: **implemented (v3), not yet live-tested** — as its own command `python -m df_llm_helper remote` (`df_llm_helper/features/remote.py`, `lua/pilot_remote.lua`; `care.py` unchanged) | Framework: see `../specs-v2/README.md` | Manual: `../manual-v3/06-remote.md`

## Goal and benefit
Save dwarves who work far away from food/drink from starving or dying of thirst in time. In run 5 a miner (4156) had been fishing for hours at the river in the north-east (100 tiles from the fort), hunger 62,000→67,000, and immediately took another fishing job after each cancelled job. Altogether several dwarves died of dehydration on long ways (fishers, deep diggers). 15 dwarves had the fishing labor.
**Expected gain:** fewer deaths; a diagnosis with 6 calls becomes 0.

## Detection
Per dwarf: hunger, thirst, position, job type, distance to the nearest food/drink place (path length approximated as Chebyshev + z penalty), duration of the current long job. Conspicuous: `hunger > 40,000` or `thirst > 40,000` and distance > 40 tiles, or job type from the list `long_jobs` (`Fish`, `Dig` deep below z110, `HarvestPlants` at the edge, `GatherPlants`).
**Implementation:** food/drink places = food stockpiles and wells (from the Lua status); distance = max(|dx|,|dy|) + `z_penalty` (3) × |dz|. An action needs hunger/thirst above the warning level AND (distance > `far_tiles` OR job in `long_jobs`) AND a labor mapped to the job (`job_labors`). The duration of a job is not measured (DF does not store a job start).

## Measures (maintenance)
1. **Cancel the job** (same as "cancel job" in the UI) and **take the matching labor away for this dwarf** (e.g. `FISH`) so he does not pick the same again at once; record in `state.db` (dwarf, labor, reason, time), return as soon as hunger/thirst < 15,000.
2. **Standing principle:** long-job labors only for a small group of well-fed dwarves (default 3; fishers: civilians only, not soldiers); all other dwarves lose them (run 5: from 15 to 3).
3. **Food/drink places** within reach of permanent workplaces are proposed (food stockpile at the river, brewer barrel in the deep mine), not built automatically.
4. **Escalation:** hunger > 55,000: warning `critical` with name/place; hunger > 65,000: hint that only moving the dwarf by hand helps.
5. **Check fishing as a food source:** yield (fish stock) in the digest; proposal to switch off if the yield < 1 fish per real hour.

**Implementation details:** taking a labor away also removes the dwarf from selective work details granting it (work detail menu); those names are recorded and restored. Records live in kv `remote_care.taken` (kind `rescue` = returned automatically on recovery; kind `pool` = rule 2, returned only by `python -m df_llm_helper remote restore`). Per dwarf at most one rescue per `repeat_block_s` (600 s); at most `max_actions_per_run` (20) writes per pass. Work details in mode "everybody does this" that grant the labor are reported (the removal cannot stick there).

## Configuration
`remote_care: {far_tiles: 40, hunger_warn: 40000, hunger_crit: 55000, long_jobs: [Fish, GatherPlants], labor_pool: {FISH: 3}}`
Implemented additionally: `thirst_warn: 40000`, `hunger_hopeless: 65000`, `recover_below: 15000`, `z_penalty: 3`, `job_labors: {Fish: FISH, GatherPlants: HERBALISM, HarvestPlants: PLANT, Dig: MINE}`, `repeat_block_s: 600`, `max_actions_per_run: 20`, `fish_min_per_hour: 1`, `in_check: true`.

## Fair play
Cancelling jobs and setting labors is normal operation (labor menu). No exception needed.

## Acceptance criteria (all covered by `tests/test_remote.py`)
1. Scenario "fisher 100 tiles away, hunger 62k": job ended, `FISH` taken away, no new fishing job within 60 s. → `test_fisher_far_away_rescued_and_no_new_fish_job_within_60s`
2. Scenario "15 dwarves with FISH": reduced to 3 (the three with the lowest hunger, not military). → `test_fifteen_fishers_reduced_to_three_lowest_hunger`
3. Return of the labor after recovery (hunger < 15,000). → `test_labor_returned_after_recovery_with_work_detail`
4. Property test: soldiers and children are never selected; no labor change for dwarves in the hospital. → `test_property_soldiers_children_never_selected_no_change_in_hospital`, `test_pool_ignores_soldiers_and_hospital`, Lua mock `test_lua_status_and_actions`
5. The escalation line appears only once per dwarf (dedupe). → `test_escalation_once_per_dwarf_and_level`

## Fixtures/tests
`units` extracts (4156, 344, 3449, 4281), job lists, labor lists (15× FISH).
**State:** `fixtures/v3/remote/*.json` are synthetic (labelled `_note`; only 4156's place/hunger follow run 5). Gaps: real `claude/pilot_remote status` output, real cancel/labor replies, real work detail membership for FISH, a raw-fish time series.

## Deviations from the draft
- Command `python -m df_llm_helper remote` instead of `python -m df_llm_helper care remote` (care.py stays untouched; the help text names the spec).
- Rule 2 only reduces (never hands out new long-job labors); soldiers holding a pool labor are not counted and not changed.
- Job duration is not tracked; "Dig deep below z110" / "HarvestPlants at the edge" are not special-cased (configure `long_jobs`).
