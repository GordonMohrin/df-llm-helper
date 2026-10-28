# BUG-106 Wound care has no audit: care gives three of five doctor labors, nothing lists what a hospital lacks
Status: fixed in the M1 commit (offline, live-untested): `inspect what=hospital` lists every gap in a fixed vocabulary with counts;
the first eight tokens are in the state (`water.gaps`) and in the brief; what the game's treatment really needs is live data
Severity: high (52 bled out, 87 suffocated in Run 14 years y526-y707, mostly patients)
Found: 2026-10-28, Run 14 post-mortem and game session note 90 ("care vergibt nur DIAGNOSE/SURGERY/BONE_SETTING ... `inspect what=hospital`
mit allen Luecken")
Module: `lua/dfllm/water.lua` (`M.audit`, `M.inspect_hospital`, `M.medic_count`, `M.state`), `lua/dfllm/kern.lua` (`INSPECT_BY`),
`dfpilot/brief.py`

## Actual
Nothing in the kernel or in the CLI said what a hospital lacked. `care` enables DIAGNOSE, SURGERY and BONE_SETTING for its doctors
(`M.MEDIC`, care.lua:138; `phase_doctors_run`) and the hospital template places beds, a traction bench, chests and a well but no table
(`dfpilot/bp/rooms.py:173-186`); the labors SUTURE and DRESSING_WOUNDS, the location's supplies (thread, cloth, splints, crutches,
plaster, soap, buckets), and the zone's place inside the refuge were nobody's check. `hospital_out` (BUG-036) and `HOSPITAL_DRY` knew
two gaps each; PATIENT_DYING knew the thirst only.

## Cause
Missing feature, not a wrong value: `water.lua` had `hospital_out`, `served` (water) and the caregivers' count, no doctor labor census,
no look at the zone's furniture or at the location's supply fields.

## Fix
`M.audit` runs once per water run (a game day), reads only what a player sees on the hospital zone, the location screen and the labors
screen, and keeps the result for `inspect what=hospital`:
- zone: `no_zone` (a hospital needs a zone with a location), `outside` (tiles outside Kern+ and the refuge, BUG-036), `dry` (no accepted
  water within `water.near`), `no_bed` (beds < max(1, patients)), `no_table`, `no_traction` (counted by `findAtTile` over the zone's
  tiles, at most 200 per zone, the first six zones);
- doctors: `no_diag`, `no_surgery`, `no_bone`, `no_suture`, `no_dress`: no adult citizen outside the squads has the labor on
  (DIAGNOSE, SURGERY, BONE_SETTING, SUTURE, DRESSING_WOUNDS), or some have it and none has the skill (`dfhack.units.getNominalSkill`);
- supplies: `no_splints`, `no_thread`, `no_cloth`, `no_crutches`, `no_plaster`, `no_soap`, `no_buckets`: the location asks for 0 ("nobody
  brings any") or holds fewer than it asks (`contents.desired_<x>`, `count_<x>`, `need_more.<x>`; fort stock of thread and cloth from
  the item census beside it), `supply_unknown` when the location shows none of these fields;
- caregivers: `no_carers` (nobody with FEED_WATER_CIVILIANS).
Each gap is `{tok, txt <= 70 bytes}`, at most 16, the whole reply under 8 KB; the message is `hospital: 6 gaps: no_table, no_traction,
...`. State `water.gaps` (first eight tokens, only while a hospital zone stands or a patient lies); brief/status care line
`hospital gaps: no_table, no_suture (dfllm cmd inspect '{"what":"hospital"}')` (rank 4, the first thing dropped when the budget is
tight); PATIENT_DYING's wake hint names the inspect. Writes nothing; `care` is unchanged (it still enables three medic labors).

## Not decided offline
- Which of these the game's treatment really requires: a table for surgery and suturing, SUTURE and DRESSING_WOUNDS as labors of the
  same doctors, plaster for casts, soap for cleaning. The vocabulary lists what a player can see; the live check is a hospital that
  heals with and without the item (inspect hospital, then the patient's wounds / `unit.job` over a week).
- The field names of the hospital location's supplies in 53.16 (`desired_splints`, `count_splints`, `need_more.splints` ... and `powder`
  for plaster): the code probes them with `pcall` and says `supply_unknown` when none exists. Read-only live check:
  `for k in pairs(df.abstract_building_hospitalst.contents)` (or the printed fields of the location object).
- Whether `care` should also enable SUTURE and DRESSING_WOUNDS for its doctors (a labor toggle on the labors screen, fair play): not
  done here, the audit comes first; once `no_suture` / `no_dress` show live, extending `M.MEDIC` is one line.
- Whether the hospital template should place a table (it does not; `no_table` will show for every kernel-built hospital).

## Tests
`tests/lua/test_water_m1.lua` (7 tests: all gaps of the note-90 case, a complete hospital, labor without skill / no fields / outside
Kern+, dry, no zone, a fort of 80, before the first run) and `tests/test_m1_care.py` (schema, state spec, config). All fail on 32994bb.

Related: BUG-034, BUG-036, BUG-054, BUG-056, BUG-104
