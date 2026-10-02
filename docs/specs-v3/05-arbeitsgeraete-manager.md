# Spec v3-05: Tool/pick manager (`python -m df_llm_helper tools`)

Priority: P0 | Date: 01.10.2026 (run 5, Y109) | Status: **implemented (v3), not yet live-tested** (`df_llm_helper/features/tools.py`, `lua/pilot_tools.lua`; uses the existing `claude/pickfix`) | Framework: see `../specs-v2/README.md` | Manual: `../manual-v3/05-tools.md`

## Goal and benefit
Make sure every miner has a work pick and dig jobs do not hang on missing equipment. This problem (E18) cost hours: 15 picks at 575 open dig jobs, 19 more lay in a bin. Causes: (a) reservation by squad uniforms, (b) work picks are only granted to dwarves whose `uniform.pickup_flags.update` flag was processed (never for non-squad miners), (c) too few dwarves with the MINE labor (16 of 34 needed).
**Expected gain:** digging capacity from 12 to 29–34 simultaneous diggers; idle from 75 % to 32 %.

## Measurements
`picks_total`, `picks_free`, `work_weapons`, `miners` (MINE labor), `diggers_now` (job type Dig), open dig jobs, number of dwarves without a pick.

## Rules (maintenance)
1. **Pick balance:** target `work_weapons >= min(miners, picks_total)`. On deviation → `claude/mil pickfix --apply` (frees reservations, deletes pick uniform specs, sets `update.weapon` and the update flag for all MINE dwarves without a pick, as many as there are free picks).
2. **More miners:** open dig jobs > 100 and `miners < picks_total` → up to 18 idle, well-fed, non-military adults join work detail "Miners" (`claude/workdetail assign`); never soldiers, never injured, never dwarves with hunger > 30,000.
3. **More picks:** `picks_total < miners + reserve 4` → forge order via `material` (bottleneck watcher v2-07 explains what is missing: iron, coke).
4. **Plausibility:** pick items in containers of the barracks count as free; output `picks_free` with location.
5. **After reload:** rule `pick_after_load` runs `pickfix` once.
6. **Digest:** `Picks 34/34, miners 34, digging 29, open dig jobs 256` or on deviation `Picks 15/34: pickfix needed`.

## Configuration
`tools: {reserve: 4, max_new_miners: 18, hunger_max: 30000, workdetail: Miners}`
Implemented additionally: `dig_jobs_min: 100`, `max_pickfix_per_hour: 6`, `repeat_block_s: 600`, `pickfix_cmd: "claude/pickfix --apply"`, `after_load: true`, `in_check: true`.

## Fair play
The per-dwarf engine flag (`pickup_flags.update`) is a direct write, but no item manipulation; documented in the exception register (FP08) with a reference to the player's yes to `foreign=false` and the pick fix. The player was informed about the flag (note from the pick agent, 01.10.).
**Implementation:** df-llm-helper only calls the pick fix if the register holds an FP08 entry whose reason (or `cmd_contains`) mentions the pick fix and that is not bound to item ids (a pure foreign-flag entry does not count); otherwise the call is refused with a clear message and a digest warning. Example: `python -m df_llm_helper exception add FP08 --reason "pick fix: per-unit pickup flag" --ja "<player quote>"`. Adding miners (work detail menu) is a normal UI action.

## Acceptance criteria (all covered by `tests/test_tools_v3.py`)
1. Scenario "15 picks, 34 picks total, 16 miners": `pickfix` executed, afterwards `work_weapons=34`. → `test_e18_adds_18_miners_then_pickfix_gives_34`
2. Scenario "open jobs 575, miners 16": rule 2 adds 18 dwarves (not soldiers/injured; property test). → `test_e18_selection_*`, `test_property_never_soldiers_children_patients_hospital_hungry`
3. Scenario "no free picks": no call, forge proposal. → `test_no_free_picks_no_call_forge_proposal`
4. Idempotence: a second run without change = no action. → `test_balanced_no_action_and_digest_line`, `test_second_run_after_fix_is_noop`, `test_same_observation_waits_for_effect`
5. Loop guard: max. 6 `pickfix` per hour. → `test_loop_guard_max_6_per_hour`

## Fixtures/tests
`work_weapons` time series, pick positions (BIN (82,99,128)), work detail lists, `items_unassigned`.
**State:** `fixtures/v3/tools/*.json` are synthetic (labelled `_note`). Gaps: real `claude/pilot_tools status`, real `claude/pickfix --apply` output with `flagged`, a `work_weapons` time series, `items_unassigned`.

## Deviations from the draft
- Rule 3 is a proposal only (no automatic forge order; the `material` scope or the player places it).
- Rule 5 detects a reload by a dropping report id (own kv key `tools.last_report`), inside `python -m df_llm_helper check`; by hand: `python -m df_llm_helper tools after-load`.
- The pick fix is called as `claude/pickfix --apply` (alias of `claude/mil pickfix --apply`; configurable).
