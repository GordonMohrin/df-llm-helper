# FEATURE-004: `hospital` watch (doctors, care jobs, water in the burrow) and plaster-raw-material check for the planner

- **Status:** proposed
- **Priority:** P1 (wounded citizens during the siege, nobody checked whether care was possible)
- **Requested by:** Gordon (player), 2026-10-02, via the local orchestrator
- **Area:** new `df_llm_helper hospital` (+ Lua `lua/pilot_hospital.lua`), extension of `care.py`, `digest`/`wake`, planner (`planners/`), `lua/claude/ueberwacher.lua:34`

## Problem
No watcher checks whether the hospital can work. The only trace is `ueberwacher.lua:34`, which appends the hint `HOSPITAL/REST(Wasser?)` to a job text when a unit has the job `Rest`. Missing: doctors with the right labors, running care jobs, water supply reachable from inside the burrow, and the raw material for plaster.

## Proposed behaviour
1. `python -m df_llm_helper hospital [--json]` (read-only), one Lua call:
   - **Staff:** number of living citizens with labors `DIAGNOSE`, `SURGERY`, `BONE_SETTING`, `SUTURING`, `DRESSING_WOUNDS`, `FEED_WATER_CIVILIANS` (`care.py` already knows the label list) and which are idle / injured / in a squad; warn if a labor has 0 holders while patients exist.
   - **Patients:** units with open wounds / `Rest` job; how many have an assigned care job (diagnose, bone set, suture, dress, feed water) and how many wait > N ticks.
   - **Hospital zone** exists and has beds/tables/containers (`hospital zone not doubled`, see memory note `feedback_df_aerzte_labors.md`).
   - **Water:** is a water source (well/water tile/drink barrel, not forbidden, see FEATURE-003) **reachable from the hospital and from the refuge burrow** (reuse `claude/mil refuge` check from BUG-423).
   - **Materials:** supplies for `DRESSING_WOUNDS` etc. (cloth, thread, splints, plaster) available and not forbidden.
2. `digest`/`wake`: `HOSPITAL: 3 patients, 0 doctors with SURGERY, water unreachable` once per state change.
3. **Plaster powder check:** "Plaster powder" (`MAKE_PLASTER_POWDER` at furnace/kiln) needs gypsum/alabaster/selenite/satin spar. The fortress rock does not contain these. The planner must check the raw material (stone type in stock via `claude/material`) **before** it creates plaster-cast (Gipsverband) orders; if missing it plans no such order and reports `plaster powder impossible: no gypsum/alabaster/selenite/satin spar in stock or on the map` (alternatives: splints from wood, trade).

## Data needed from the game
Unit labors (`unit.status.labors`), wounds (`unit.body.wounds`), jobs (`unit.job.current_job.job_type`), zones (`building_civzonest` hospital flag), burrow tiles, items (type, forbid), stone material lists for the plaster check. Mostly available in `care.py`/`pilot_care.lua`.

## Safety / fair play
Read-only analysis. The planner only proposes orders (existing `orders` flow); no item/unit manipulation.

## Acceptance criteria (fixture based)
1. Fixture "patients, no surgeon": output lists the missing labor and the patients waiting.
2. Fixture "burrow without water source": `water unreachable` reported (same input shape as BUG-423 selftest).
3. Fixture "no gypsum-class stone in stock": the plan contains no plaster-cast order and prints the reason; with a stock of alabaster the order is allowed.
4. Fixture "all ok": one line `Hospital ok`, no wake line on the second run.

## Info needed
Player: recorded answer of `claude/gesund` (or `pilot_care`) with at least one patient; list of stone types present in stock (`claude/material`) to build the plaster fixture.

## Addendum 2026-10-02 (root cause found live): hospital location posts were all empty
The hospital (location 11, zone 3760) has 8 location posts (occupations 6..13: 2x DOCTOR, 2x DIAGNOSTICIAN, 2x SURGEON, 2x BONE_DOCTOR in `world.occupations.all`, field `location_id`, `unit_id` -1 = unfilled). With no post filled the hospital counts as not functional (DFHack `notify` shows this, see also run 1/run 5 notes) and **no care jobs are created at all** (no diagnosis, no water, no dressing), even if citizens have the labors. Labors alone do not help.
Required in the watcher / planner:
1. Check per hospital location that at least one DOCTOR post, or DIAGNOSTICIAN + SURGEON + BONE_DOCTOR, is filled by a living adult unit; report `HOSPITAL: no staff posts filled` as critical when patients exist.
2. Suggest candidates (alive, adult, not in a squad on duty, not in a mood, low stress, healthy) and, with an exception register entry, fill the posts the way the location menu does: `occupation.unit_id`, `occupation.histfig_id` and `unit.occupations:insert` (tested live 02.10.2026, FP13, 8 posts filled), plus the care labors DIAGNOSE, SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS, FEED_WATER_CIVILIANS, RECOVER_WOUNDED.
3. Re-check after deaths (the post keeps pointing at the dead unit); orphaned HOSPITAL locations without a zone (ids 0, 3, 4, 10) should be listed.
Acceptance: fixture "8 posts unfilled" -> critical + 8 suggestions; fixture "all filled by living units" -> ok; fixture "post points at dead unit" -> treated as unfilled.

## Nachtrag 2026-10-03
- The hospital workplace slots (occupations) were empty -> no care jobs. Staffing via Lua worked live (8 slots): set `occupation.unit_id` / `occupation.histfig_id` and `unit.occupations:insert(...)`. After a death the slot still points at the dead unit -> `hospital` should detect dead holders and refill (with `--apply`).
