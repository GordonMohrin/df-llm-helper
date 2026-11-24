# BUG-821 water.carers wanted no caregiver until a patient lay in bed; patients thirsted while the detail filled
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-23, Run 16 i1/i2/i4 (patients dead of thirst, some with no GiveWater job); NEU1 P9 (decision E8)
Module: `lua/dfllm/water.lua` (`M.carers`, config `water.carers_standing`)

## Actual
`M.carers` set `want = 0` while `#r.patients == 0`: the Orderlies detail got its first members only after a patient was registered, then at most `carers_per_run` a run. The first patients of a fight lay a day or more with no caregiver.

## Fix
While a hospital zone stands (`r.hosp` non-empty) and `water.carers_standing` is on (default), `want` is at least `carers_min`, patient or not. The hold timer still counts from the last patient; after `carers_hold_days` the kernel's own extra members leave one a run down to `carers_min`, not to zero. Off: the old rule.

## Open
Whether GiveWater then reaches the patient in time (Run 16d i4 y384: jobs ran, the patient died anyway) is not proven offline.

## Tests
`tests/lua/test_neu1_pflege.lua` (water.carers_standing), `tests/lua/test_water.lua` (BUG-054 hysteresis pinned to the old rule). Design: `docs/v2/NEU1-pflege.md`.

## Live-Erwartung
1. A fort with a hospital zone keeps `water.carers_standing` caregivers assigned before the first patient lies in bed (kern.log / `inspect what=hospital` shows the carers with no patient).
2. A patient in bed gets a GiveWater job within a game day; no patient dies of thirst while drink stands in the fort.
