# BUG-103 A strange mood, a thirst or a hunger of a unit that is no citizen raises MOOD_CRITICAL, a decision and a hospital removal
Status: fixed in the M1 commit (offline, live-untested): `care` (mood), `water` (patients, caregivers), `reflex` (confined_need) and
`economy` (supply alarm, hungry count) read citizens only (`dfhack.units.isCitizen`, `lua/dfllm/util/who.lua`)
Severity: medium (a wake and a decision that nothing can answer; a resident patient far away could remove a hospital's zones)
Found: 2026-10-24, Run 14 (Trussroads), game session note 74 (unit 38663, "Zasit Zonrôber", Wax Worker, Fey, thirst/hunger 67,117 of
75,000, "workshop none claimed", `civ_id` 29, `isCitizen()` false, at 190,23,133 far outside the fort near the caravan wagons)
Module: `lua/dfllm/care.lua` (`mood_seen`), `lua/dfllm/water.lua` (`phase_units`), `lua/dfllm/reflex.lua` (`need_step`),
`lua/dfllm/economy.lua` (`needs`, `hungry_ids`), `lua/dfllm/util/who.lua` (new)

## Actual
MOOD_CRITICAL and DECISION_NEEDED named a dwarf who is a member of another civilization (a caravan's, per the note), 140 tiles from the
fort. The note filed it as "no citizen, not ours" and did nothing, correctly: no workshop, material, drink nook or caregiver of ours
reaches such a unit, so the wake could only ask the player for what cannot be done (and each such wake costs a subagent).

## Cause (proven from the code at 32994bb)
1. **The census is wider than the citizens.** `sense.lua:120` reads `U.getCitizens(false, true)` (residents included) and counts a unit
   as a member when `U.isCitizen(u) or U.isResident(u)` (sense.lua:127): `census.u.ids` holds the fort's residents too (BUG-088 found the
   same for the recruit list). A unit with `isCitizen` false in a care report can only have come through `isResident`.
2. **Every per-unit reader of the census trusted it:**
   - `care.mood_watch` (care.lua:3663-3678, the fast mood check) and `care.look_unit` (care.lua:658-671, the full run) call `mood_seen`
     (care.lua:538) for every unit with a strange mood. `mood_seen` creates the record `p.moods` (care.lua:544), and emits MOOD_START,
     MOOD_RISK (589), MOOD_CRITICAL (606), MOOD_NEED, the `mood_workshop` DECISION_NEEDED, the drink nook and the mood wants for
     economy. None of them asks `isCitizen`. (`look_unit` filters nothing; `a.res` counts non-citizens only for the stress statistics.)
   - `water.phase_units` (water.lua:267-299) takes every census unit with `needs_healthcare` or a Rest job as a patient (273) and every
     adult with the FEED_WATER_CIVILIANS labor as a caregiver (281). A resident patient over `patient_thirst` raises patient_thirst /
     PATIENT_DYING and, in a hospital without accepted water, `remove_dry` (water.lua:815, the hospital's zones are removed).
   - `reflex.need_step` (reflex.lua:2052-2090) reads thirst and hunger of every census unit with a mood or a patient mark and raises
     the `confined_need` decision, and ends the lockdown "for him" (the release path).
   - `economy.needs` (economy.lua:2799) and `hungry_ids` (economy.lua:4594) count the thirsty and the hungry of the census for the
     supply alarm and the `HUNGRY n` stock line.
3. **Not affected (checked):** `readiness.lua` reads counts of the census (`cit`, `adults`), no per-unit thirst, hunger or mood;
   `siege`/`gate` read thirst of units by id for their own rescue and puller rules (STRANDED, PULLER_THIRST) and are other packages;
   `deaths.lua:243` reads the thirst of a citizen who died (the cause of death), not a report about the living.

## Fix
- `util/who.lua` `citizen(u)`: `pcall(dfhack.units.isCitizen, u)`, the same predicate as `military.citizen` (BUG-088).
- `care.mood_seen` returns at once for a non-citizen and drops a record an older kernel kept (`p.moods[sid]`, `p.nook[sid]`) without
  a MOOD_END; the later phases (MOOD_NEED, the slots, the wants) see no record and skip him. Strange moods of citizens are untouched.
- `water.phase_units`: a non-citizen is neither patient nor caregiver nor home position (`r.outsiders` counts them for the audit).
- `reflex.need_step`: only citizens count for `confined_need` and for ending the lockdown.
- `economy.needs`, `economy.hungry_ids`: citizens only.
- A fort of 7 or 80, SIEGE, BREACH, a lockdown, a reclaimed fort: nothing but the unit filter changed; a resident that is a patient in
  a hospital with real water gets his water from the caregivers anyway (the game's jobs), the kernel just does not report him.

## Not decided offline
- Whether a resident in a strange mood who really claimed one of our workshops should be served (this fix treats every non-citizen
  alike, as the task demanded). Read-only live data: for such a unit `dfhack.units.isResident`, `isMerchant`, `isVisitor`, `civ_id`,
  `unit.mood`, the claimed workshop's id (`job.holder`), position.
- Why `isResident` was true for unit 38663 at all (a caravan member standing on the map edge should be neither).

## Tests
`tests/lua/test_care_m1.lua` (3 tests: resident and merchant in a mood at 76,000 raise nothing, a citizen still does; an older record is
dropped silently; no workshop request or mood want), `tests/lua/test_water_m1.lua` (a resident patient at 70,000 raises no
patient_thirst, PATIENT_DYING or removal and is no caregiver), `tests/lua/test_reflex_m1.lua` (confined_need), `tests/lua/test_economy_m1.lua`
(supply alarm). All fail on 32994bb.

Related: BUG-088, BUG-100, BUG-102, FR-82
