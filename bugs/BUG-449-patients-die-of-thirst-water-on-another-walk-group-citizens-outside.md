# BUG-449 patients die of thirst under "GiveWater jobs running"; citizens starve at the water outside
Status: fixed (offline, live-untested); open: the real cause of the Syrupobeyed deaths is not proven, no automatic recall
Severity: high
Found: 2026-11-05, Run 16a i1 Syrupobeyed y384-y386 (patients 26481 and 26664, bed area 94,113,135), Run 16d i4 Mazelanterns y403-y408 (citizens at x164-191,y156-191,z138)
Module: `lua/dfllm/water.lua` (give_diag, src_reach, patient_cmds, src_near), `lua/dfllm/siege.lua` (dry_decision), `dfpilot/schema.py`

## Actual
- i1: two patients died of thirst in the same bed area under "1-4 GiveWater jobs running 25+ days without effect", hospital ok, 25 buckets (15 free), caregivers 79 (51 idle), the nearest accepted water a zone at 106,109,139 (12 tiles, four levels up).
  BUG-434 (round 27) does not cover it: the zone is near (< `patient_far` 40) and a cistern was never the question. BUG-383's release found "nothing to release": the carriers 26274, 26272, ... are no members of the Orderlies detail.
  The verdict `run`/`noeffect` never asked WHERE the water is; the DECISION had no command.
- i4: 5-6 citizens a day stood at the only accepted water, a zone 101 tiles out at the map edge, hunger 70-120k, 8 starved; the fort had no accepted water inside, so they went out to drink. `stranded_food` offered a farm search.

## Fix
- `water.src_reach` + `give_diag`: when the nearest accepted sources (up to 8) lie on another walk group than the patient (snapshot.groups with the neighbour lookup: a zone tile is water, not floor), the verdict is `srcreach`: "no accepted
  water on the walk group G of the patient: the nearest, zone N at x,y,z (d tiles), lies on group H (the carriers cannot fetch it): a cistern beside him"; unknown groups give no verdict. Not proven for i1 (no live read of the groups); it is the one cause
  the diagnosis could not see and the logs allow.
- `patient_thirst` DECISION_NEEDED and `PATIENT_DYING` carry `cmds` (a cistern at the patient's position for `srcreach`, `inspect what=unit key=<id>`, `inspect what=hospital`, `what=reach`, `what=water_sources`) and `unrel` (carriers that are no Orderlies
  member, which BUG-383 cannot release).
- `water.src_near` + `siege.dry_decision`: the stranded stand within 20 tiles of an accepted source that is not inside Kern+/Tiefe+: the question starts "they stand at <source>, the only accepted water of the fort (they went out to drink): bring water
  inside first", `at_water`, commands `bp sites cistern --fresh` and `inspect what=entrances`. BUG-446's `no_water` (water > 40 tiles away, drink short) and BUG-434's patient cistern request are the preventive half.
- Not done: an automatic recall of citizens outside the main walk group (no verb or alert exists for it in PEACE).

## Tests
`tests/lua/test_bug446_449_water.lua` (src_reach, give_diag, cmds), `tests/lua/test_stranded.lua` (the decision text).

## Live check
At the next PATIENT_DYING with `key: noeffect` or `srcreach`: `d.cmds`, `d.unrel`; run `inspect what=unit key=<id>` for the job and position.

## Review fix (pre-deploy review of round 28)
- `water.src_reach` asked `snapshot.groups` for the patient and the zone centres in one call without `prefer`: a zone / well tile is water, no floor, so it resolves to its first walkable neighbour, often another group than the patient's: a false `srcreach`. Now the patient's group is read first and the sources are resolved with it as `prefer` (as economy does, BUG-390).
- `srcreach` no longer pre-empts the verdict: with GiveWater jobs open / stuck / running the verdict stays `stuck` / `open` / `run` (so `give_effect` -> `noeffect` and the BUG-383 carrier release run), the finding is added to the reason and `gv.srcreach`; `patient_cmds` still offers the cistern command. Only with no job posted at all is `srcreach` the verdict.
- Tests: `tests/lua/test_bug446_449_water.lua` (zone tile with neighbours on two groups; srcreach with a running job -> noeffect).
