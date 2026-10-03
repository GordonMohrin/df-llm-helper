# Hospital watch (`python -m df_llm_helper hospital`) – FEATURE-004

Status: implemented, **not yet live-tested**. The Lua part (`lua/pilot_hospital.lua`, installed as
`claude/pilot_hospital`) is LIVE-UNTESTED; `status` is read-only, `staff` writes only with `--apply`.

Can the hospital work? Root cause found live (02.10.2026): the hospital location's staff posts (DOCTOR,
DIAGNOSTICIAN, SURGEON, BONE_DOCTOR in `world.occupations`) were all empty, and then the game creates **no care jobs
at all** (no diagnosis, no water, no dressing), whatever labors the citizens have. After a death the post keeps
pointing at the dead unit.

## Commands
| Command | What it does | DF access |
|---|---|---|
| `python -m df_llm_helper hospital [--json]` | summary line, problems (`!!` critical, `!` warning), staff per care labor, patients with their care jobs, orphaned locations, supplies, successor per unfilled post, supply plan; exit 1 on problems | `claude/pilot_hospital status` (read only) |
| `python -m df_llm_helper hospital staff [--apply]` | fills the unfilled posts like the location menu (`pilot_hospital staff <post> <unit> --apply`) and gives the new staff the care labors (`pilot_care labors`); without `--apply` the plan only; `--apply` needs the register entry `HOSPITAL` | `claude/pilot_hospital staff`, `claude/pilot_care labors` |
| `python -m df_llm_helper hospital plan` | medical supply planner: splints/crutches (wood), plaster powder only with gypsum-class stone | read only |
| `--file status.json` | offline on a recorded `pilot_hospital status` answer (all three actions) | none |

Example (fixture `fixtures/v3/hospital/status_posts_unfilled.json`):
```
HOSPITAL: 1 patients, no staff posts filled
!! no staff posts filled
orphaned hospital locations without a zone: [0, 3, 4, 10] (report only)
post DOCTOR #6 (location 11) -> 4402 Ast Omerlolum (care skill 14)
...
```

## Checks
- **Staff posts:** per hospital location with a zone, one DOCTOR post or DIAGNOSTICIAN + SURGEON + BONE_DOCTOR must be
  filled by a living adult; otherwise `no staff posts filled` (critical with patients). A post that points at a dead
  unit counts as unfilled and is listed (`posts held by dead units`). Orphaned HOSPITAL locations (no zone) are listed
  only. Candidates: alive, adult, no squad, no mood, no pickaxe (miners keep digging), not a patient, no prisoner,
  stress <= `hospital.stress_max`; best care skill first, one unit per post.
- **Labors:** citizens per DIAGNOSE, SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS, FEED_WATER_CIVILIANS (idle,
  injured, in a squad); `0 doctors with <LABOR>` when a labor has no holder while patients exist.
- **Patients** (as in `care`: cannot stand, resting, or wounded in the hospital): care jobs that name them
  (`UNIT_PATIENT` ref); a patient without a care job for `hospital.wait_ticks` (2400) game ticks is `waiting`.
- **Zone:** hospital zone exists, beds (critical with patients), a table (surgery), a chest (supplies); overlapping
  zones are reported, never deleted.
- **Water:** a well (tested from the tiles around it) or an unforbidden drink reachable from each hospital zone
  (`water unreachable from the hospital`, critical with patients); the refuge burrow's supply from
  `claude/gefahr` `refuge_supply` (BUG-423 shape; `water unreachable in the refuge burrow`).
- **Supplies:** cloth, thread, splints, crutches, plaster powder, soap; forbidden ones apart (`supplies only forbidden`);
  missing cloth/thread/splints with patients.
- **Digest/wake:** `check` runs the watch every `hospital.every_s` (600 s; the status call walks all items once). The state is the set of problem KINDS (not
  the counts): a change writes one warning (crit -> one wake line), unchanged stays silent, `Hospital ok ... (resolved)`
  when fixed. `claude/ueberwacher` now names the watch in its `HOSPITAL/REST` hint.

## Plaster check (planner `planners/medical.py`)
Plaster casts need plaster powder (kiln reaction `MAKE_PLASTER_POWDER`), and that needs gypsum, alabaster, selenite or
satinspar. `plan_medical(stock, gypsum)` proposes a plaster order only when such boulders exist (in stock or on
visible tiles; `pilot_hospital status` field `gypsum`, or a `claude/material`-style `{STONE: n}` list); otherwise the
plan says `plaster powder impossible: no gypsum/alabaster/selenite/satin spar in stock or on the map (alternatives:
splints from wood, trade)`. Splints and crutches are proposed from wood (or a note to buy them); cloth/thread/soap
shortages are notes. Proposals only: nothing is ordered (use `claude/orders` / the manager).

## Fair play
`status` and `plan` read only own buildings, own items and visible tiles (no hidden stone). `staff --apply` does what
the location menu does (occupation holder + the unit's occupation list; old values in `tools/out/hospital-log.json`)
and only with the player's consent:
```bash
python -m df_llm_helper exception add HOSPITAL --local --reason "staff the hospital" --ja "<verbatim quote>"
```
The Lua refuses posts held by a living unit, posts of a location without a zone, and units that are not citizens,
dead, children, in a mood, soldiers, patients or prisoners.
