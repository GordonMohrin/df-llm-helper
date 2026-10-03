# FEATURE-004: `hospital` watch (doctors, care jobs, water in the burrow) and plaster-raw-material check for the planner

- **Status:** implemented in c8258fc
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

## Implementation
Commit c8258fc. Code `df_llm_helper/features/hospital.py` (plug-in, config section `hospital`), pure post/staff rules
in `df_llm_helper/care.py` (`post_filled`, `location_staffed`, `unfilled_posts`, `labor_staff`, `post_candidates`),
planner `df_llm_helper/planners/medical.py` (`plan_medical`), Lua `lua/pilot_hospital.lua` (`status` read only,
`staff <occupation> <unit> [--apply]`), hint in `lua/claude/ueberwacher.lua`; tests `tests/test_hospital.py`; fixtures
`fixtures/v3/hospital/` (synthetic); manual `docs/manual-v3/13-hospital.md`.

- Commands: `python -m df_llm_helper hospital [--json] [--file F]`, `hospital staff [--apply]`, `hospital plan`;
  `check` runs the watch every `hospital.every_s` (600 s).
- Staff posts (addendum): a location with a zone needs one DOCTOR or DIAGNOSTICIAN + SURGEON + BONE_DOCTOR filled by a
  living adult; a post on a dead unit is unfilled; orphaned locations are listed (report only). `hospital staff
  --apply` fills the posts as tested live (occupation unit/histfig + `unit.occupations` insert, dead holder unlinked
  first, log `tools/out/hospital-log.json`) and sets the care labors through `claude/pilot_care labors`; it needs the
  new register consent action `HOSPITAL` (`exception add HOSPITAL ...`), dry run otherwise.
- Water: wells (tested from the tiles around them) and unforbidden drinks reachable from each hospital zone; the
  refuge burrow is read from `claude/gefahr` `refuge_supply` (BUG-423 shape). The full refuge reachability check is
  FEATURE-005 (not duplicated here).
- Plaster: `plan_medical` proposes `MAKE_PLASTER_POWDER` (kiln) only when gypsum-class boulders exist (gypsum,
  alabaster, selenite, satinspar, or reaction class GYPSUM; visible tiles only), otherwise the note
  `plaster powder impossible: ...`. Proposals only; no order is created (the existing `claude/orders` flow has no
  plaster order, so nothing there needed a gate).
- Safe subset: patient waiting time is measured between watch runs (first tick without a care job, kept in state.db),
  not from the game's own timers.

### Live check
1. `python -m df_llm_helper install-lua --apply` (installs `claude/pilot_hospital`), then `claude/pilot_hospital
   status` in DFHack: compare `locations[].posts` with the hospital's location menu (8 posts, location 11) and
   `hospitals[]` with the zone (beds, table, chest).
2. `python -m df_llm_helper hospital`: summary line, posts, suggestions plausible? `hospital plan`: plaster note
   correct for the fort's stone (no gypsum-class stone in Run 5)?
3. `python -m df_llm_helper exception add HOSPITAL --local --reason "staff the hospital" --ja "<quote>"`, then
   `hospital staff` (plan) and `hospital staff --apply`; check the location menu shows the staff and that care jobs
   (DiagnosePatient, GiveWater) appear for a wounded dwarf.
4. `python -m df_llm_helper check` twice: the hospital line only on a change; `wake` shows one line when a doctor dies
   and his post points at the dead unit.
