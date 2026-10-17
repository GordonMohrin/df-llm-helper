# BUG-036 Patients killed in their hospital beds during the BREACH: the hospital lay outside the refuge
Status: fixed in 5e6d754 (offline, live-untested): readiness R0 blocker `hospital_out` (a hospital zone outside Kern+/Tiefe+, water
state `hosp_out`), named in SIEGE_UNREADY, `status`/`brief` and the wake line with the fix; `plan check` warns; in a
fight PATIENTS_OUT (B) says once how many patients lie outside the alert burrow
Severity: critical (loses citizens: 7 patients and their wounded soldiers struck down where they lay)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y445, siege 9 (invasion 13), dfpilot main 784399f, from the game
session's death records
Module: `lua/dfllm/water.lua` (hospital zones), `lua/dfllm/readiness.lua` (R0 blockers), `dfpilot/plan.py` (check),
`dfpilot/brief.py`, `dfpilot/wake.py`

## Actual
- Siege 9: 10 citizens lost, all in the BREACH. 8 were struck down by the cave dragons 28392/28393, 7 of them flagged
  patient (injured, in hospital beds); 2 bled out at 115,77,144 and 124,91,144 (one a patient). No goblin among the
  killers. The dragons reached the bed/hospital area.
- The wounded soldiers (16 -> 6) lay there as patients; nobody moved them into Tiefe+, the refuge the alert confined to.
- Nothing had said before the siege that the hospital lay outside the refuge; readiness knew only `refuge_dry` etc.

## Cause
A lying patient cannot walk: the civ alert's burrow means nothing to him, in DF only a rescue (or hauling) moves him.
So the hospital itself must lie where the patients are safe in a breach: in Tiefe+ (or at least in Kern+ behind the
seal). Neither readiness, the plan check nor the water module looked at where the hospital lies; BUG-034 (Run 11 y439)
only made it lie next to accepted water. The kernel cannot move units or items (fair play), and painting the burrow over
the hospital moves nobody: the fix is a hospital built inside, which is the plan's (the player's) job.

## Expected
Before a siege, a hospital outside Kern+/Tiefe+ is a readiness blocker with its fix (a hospital inside Tiefe+ next to
accepted water: both rules, BUG-034 and this one, hold at once); in a fight the brief says how many patients lie outside
the alert burrow, once.

## Fix
- **water:** per hospital zone the tiles of its rect (<= 100, an even sample of a bigger one) on neither Kern+ nor the
  refuge: state `water.hosp_out` (zones), kpi, `water.hospital_out()` (the zones with their centre); the log line says
  `hospital ok (1 of 2 zones outside Kern+/Tiefe+)`. In SIEGE/BREACH, once per fight, PATIENTS_OUT (B): the patients
  (needing health care or resting in bed) on no tile of the burrow the alert confines to (Kern+/Tiefe+ while it is
  silent): `BREACH: 7 of 7 patients lie outside the alert burrow Tiefe+ (...): they cannot walk there, only a rescue
  moves them; the hospital lies outside Kern+/Tiefe+: move it into Tiefe+ next to accepted water`.
- **readiness:** R0 blocker `hospital_out` while `water.hosp_out` > 0 (no water state: no blocker, fail-open);
  SIEGE_UNREADY `hout` and the text `the hospital lies outside Kern+/Tiefe+ (1 of 2 zones; zone 34 at 115,77,144): its
  patients cannot walk to the refuge; move it into Tiefe+ next to accepted water`.
- **Python:** the wake line (`next: the hospital lies outside the core: plan it inside Tiefe+ next to accepted water (bp
  sites hospital; a cistern there first), then remove the old zones`), `status`/`brief` (UNREADY `next:`), `plan check`
  warnings while `water.hosp_out` > 0 (and for a new hospital in the plan: its site must lie inside Tiefe+/Kern+). The
  plan cannot see burrow tiles; the kernel's count decides once the hospital stands (BUG-034's water check still
  refuses a hospital without accepted water near its site).

## Not decided offline
- Where Run 11's hospital lay against Kern+/Tiefe+ (115,77,144 and 124,91,144 are the two bleed-out tiles): the next
  water log line `hospital ... (N of M zones outside Kern+/Tiefe+)` and `water.hospital_out()` (inspect) say it.
- Whether DF moves a patient during a civ alert at all (rescue jobs): PATIENTS_OUT at the next fight with the units and
  their positions a few hundred ticks later would show it.

## Tests
`tests/lua/test_water.lua` (hosp_out, the sampled big zone, PATIENTS_OUT once per fight, against the alert burrow and
against Kern+/Tiefe+ while it is silent), `tests/lua/test_readiness.lua` (R0 `hospital_out`, the text, fail-open),
`tests/test_hospital_water.py` (contracts, plan check warnings), `tests/test_cli_status.py`, `tests/test_cli_wake.py`;
each fails on cea6072.
