# BUG-596 Patients die of thirst in a long siege: "Pflege+ not opened: no fresh hostile census" (more than 40 hostiles in sight)
Status: fixed (offline, live-untested)
Severity: high (2 patients died of thirst, the same line 14 times)
Found: 2026-11-09, Run 16b i2 Brotherarrow y406-y414 (57 hostiles in sight for 100+ days; DECISION patient_thirst 14x "the civ alert holds the caregivers in Tiefe+, the patient lies outside; Pflege+ not opened: patient 26439: no fresh hostile census")
Module: `lua/dfllm/water.lua` (`M.foe_dist`, `care_step`, the patient_thirst wake), `lua/dfllm/sense.lua` (`hscan_finish`)

## Actual
The hospital lay outside Tiefe+ (the alert burrow), the carers inside. The care burrow Pflege+ (the way out for the water) never opened; the DECISION repeated every week with the same text; two patients died of thirst.

## Root cause
`water.foe_dist` returns nil ("unknown, never far") when the census sees more hostiles than it lists (`h.vis > #h.list`; sense lists the 40 nearest O1). With 57 hostiles in sight that was true for the whole siege, and `care_safe` turns nil into "no fresh hostile census". The census was fresh; it was cut.

## Fix
`sense.hscan_finish` publishes the cut: `h.lo` (the distance to O1 of the last listed hostile; every unlisted one is at least that far; only when the list ended outside both zones) and `h.o1`. `foe_dist` bounds the unlisted hostiles by the triangle inequality (`lo - d(tile, O1)`) and returns the smaller of that and the nearest listed one; nil only when the bound is not positive or the census predates the fields. The patient_thirst reminder, while its cause is the alert alone (`gv.key == 'alert'`) and the care burrow is closed, repeats at `M.ALERT_REPEAT` (4) times `alarm_every` (a new patient still wakes at once).

## Tests
`tests/lua/test_bug595_597_refuge_siege.lua` (3) (57 in sight, 40 listed: opens with the bound, stays closed when the unlisted may be 12 tiles away, stays closed without the bound) and the reminder test; `test_bug330_care_burrow.lua` (3) unchanged (no bound: nil).

## Live check
Long siege with more than 40 hostiles: kern.log `care burrow Pflege+ opened to patient(s)` while the army is far; patient_thirst no more than once per 4 weeks for the same patient.

Not done: moving the patient into the refuge before the confinement (a bedridden patient cannot walk, only a rescue moves him; the care burrow is the way for the water).

Related: BUG-330, BUG-559, BUG-571
