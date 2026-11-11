# BUG-755 a hospital with fewer beds than patients: nothing adds beds
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y435-y437: 10-16 patients, 4 beds; the audit said `no_bed` and nothing asked for beds
Module: `dfpilot/bp/rooms.py` (`hospital`, `_furnish_hospital`), `dfpilot/bp/sites.py`, `dfpilot/plan.py` (`hospital_table`), `lua/dfllm/water.lua` (`M.SUPPLY_FIX`, `M.SUPPLY_ORDER`)

## Actual
`water.audit` raises the gap `no_bed` ("N beds in the zone for M patients"), but `hospital_supply` (BUG-537) did not list it and `plan propose` drafted only the table (`furnish=1`). A hospital room that stands got no more beds.

## Root cause
`SUPPLY_FIX` / `SUPPLY_ORDER` knew table, traction bench, splints, thread and cloth; `hospital furnish` was one table only.

## Fix
`hospital furnish=2` is one bed on a free floor tile of the hospital room that stands (`rooms.PARAMS` range 0..2, `sites._furnish_hospital(.., "bed")`). `SUPPLY_FIX.no_bed` names it (first in `SUPPLY_ORDER`) with the `bp.place` command; `plan.hospital_table` drafts up to `HOSPITAL_BED_OPEN` (3) bed projects at once and `HOSPITAL_BED_MAX` (8) per fort for a `no_bed` gap; a bed project no longer counts as the table (the table counts `furnish == 1` only).

## Open
One bed per project, beside a wall of the room (like the table); a room with no free wall-side floor refuses with the existing "no open floor tile" text. A bed needs wood from the carpenters.

## Tests
`tests/test_bug755_f48_tant.py` (template, rank, validate, draft limits, the table still drafted), `tests/lua/test_water_m1.lua` ("BUG-755": the DECISION names `no_bed` with the command). The `T.done()` in the middle of `test_water_m1.lua` (it ended the file before the BUG-537 test, which therefore never ran) is moved to the end.

## Live check
`inspect what=hospital` with more patients than beds: `hospital_supply` names the bed; after the projects the gap `no_bed` is gone.
