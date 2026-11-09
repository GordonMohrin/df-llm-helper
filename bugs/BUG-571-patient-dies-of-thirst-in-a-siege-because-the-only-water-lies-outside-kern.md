# BUG-571 a patient dies of thirst in a long SIEGE: the only accepted water lies one level above Kern+, the care burrow wants every tile on Kern+
Status: fixed (offline, live-untested)
Severity: high (patient 27722, the militia commander, thirst 6,545 -> 67,851 in ~25 days)
Found: 2026-11-06, Run 16b i2 Brotherarrow y406 (`runs/run-16b/FR-BUGS.md` "BUG (KRITISCH) SIEGE_DEEP-Refuge Tiefe+ hat 0 Essen", "Hungertod-Welle", "Patient 27722 verdurstet", "Manager Onget validiert 48 Tage nichts")
Module: `lua/dfllm/water.lua` (`care_step`, `care_check`, `care_ext`), `dfpilot/fairplay.py`

## Actual
The Deepcore hospital (patient at 100,106,133) had a dry well; the only accepted source was the pond zone 17696 at 102,108,138, z138, one level above Kern+ (z122-137). DECISION patient_thirst (#9295/#9341): `the civ alert holds the caregivers in Tiefe+, the patient lies outside; Pflege+ not opened: every accepted water outside the alert burrows has a hostile near it or lies outside Kern+`; PATIENT_DYING #9374; `water.unstick` and `hospital.*` did not help. The hostiles were 50+ tiles off, 14 from one entrance.

## Root cause
`water.lua` `care_step` (old lines 2723-2726): outside PEACE/ALERT `strict` is true and `inside(x, y, z)` accepted only tiles on Kern+ (`unforbid_ok`'s rule, review fix merge14), for the patient, the water source (`src_tiles`) and the bucket. A source one tile outside Kern+ was never a candidate, however sealed the walls and however far the army.

## Fix
In a SIEGE (never a BREACH) `care_step` / `care_check` may use patient, source and bucket tiles outside Kern+ when (config `water.care_siege_out`, default true) seal's entrance check says the fort is sealed (`seal.groups().sealed`, fresh: no route from the map edge to a citizen after the last change, `care_ext`), the tile lies on the citizens' own walk groups (`snapshot.far` false: inside the walls) and no visible hostile is within `water.care_siege_near` (40, against `care_near` 20 on Kern+) tiles of it (every tile of a zone). An open care burrow re-checks the walls' seal and the wider distance for those tiles on every ask (`care_check`: `the walls are not verified sealed any more`). The close reason names the rule when it blocks (`outside it only with the walls verified sealed, BUG-571`). Carrying drink from the refuge barrels (the report's second wish) is not done.

## Tests
`tests/lua/test_bug571_care_siege_out.lua`: SIEGE, the only well outside Kern+, sealed, on the citizens' groups, the army 80 tiles off: the care burrow opens with the patient, the well and a bucket (old: closed); not sealed / outside the walls: closed; a hostile 35 tiles from the well: closed (care_near is 20), 45: open, the seal lost: closed at once with the log line; BREACH and `care_siege_out` false: the old rule. `tests/test_bug569_572_f36.py`: config keys.

## Live check
`dfllm cmd inspect what=water_sources` with the pond zone outside Kern+ during a long siege: `kern.log water: care burrow Pflege+ opened ... outside` and the patient's thirst falls; with a hostile within 40 tiles of the pond it stays closed and the DECISION says why.
