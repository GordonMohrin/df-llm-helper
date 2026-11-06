# BUG-537 HOSPITAL_DRY is raised ~10 times a year beside a hospital whose water flickers; hospitals lack a table, splints, thread and cloth and nobody is asked
Status: fixed (offline, live-untested)
Severity: low (noise) and medium (wounds not treated)
Found: 2026-11-06, Run 16c i3 Sealcertain y380-y385 (`runs/run-16c/FR-BUGS.md`, R11 report "HOSPITAL_DRY flackert 10x/Jahr", "Hospital ohne Tisch/Thread"; events.jsonl: 29 HOSPITAL_DRY / HOSPITAL_REMOVED with the same well 17732 at 1/7, 2/7, 0/7 below, read only)
Module: `lua/dfllm/water.lua` (the hospital gate, `M.supply_ask`), `dfpilot/bp/rooms.py` (`hospital`, `_surface_hospital`), `dfpilot/wake.py`

## Actual
The same dry well (`2/7 below, shallow: < 3/7`) produced a new HOSPITAL_DRY every few thousand ticks. `inspect what=hospital` listed `no_table`, `no_splints`, `no_thread`, `no_cloth`, nothing asked for them, and the hospital template had no table.

## Root cause
`water.lua` (gate block, "a new dry episode wakes at once"): the episode record (`p.hosp*`) was cleared in the first run that found accepted water; a well that read 3/7 for a day and 1/7 the next started a new episode, and a new episode wakes at once (`start = p.hosp == nil`). The template: `hospital` and `_surface_hospital` place beds, a traction bench and chests but no table (`t`). The audit (BUG-106) names the gaps but is a list for `inspect`, not a decision.

## Fix
`gate_clear` (3 days): accepted water starts a clear clock (`p.hosp_ok`); the episode and its record end only when it has held that long, a dry run in between restarts the clock. Both templates place a table (`t`). `M.supply_ask`: a hospital with a patient and a `no_table / no_traction / no_splints / no_thread / no_cloth` gap raises DECISION_NEEDED `hospital_supply` (A) with `gaps`, `q` and `cmds` (`order.add ConstructSplint`, `trade.want thread` / `cloth`), once per `hosp_sup_every` (28 days) and again for a changed set of gaps (util/cadence); `wake.hospital_supply_hint` says it is the player-agent's own call.

## Tests
`tests/lua/test_water.lua` (flicker; the episode test now waits `gate_clear`), `tests/lua/test_water_m1.lua` (hospital_supply), `tests/test_bug535_538_f33.py` (wake line), the bp goldens (regenerated for the table).

## Live check
HOSPITAL_DRY of a well that flickers: once per episode (plus the weekly repeat with patients); `hospital_supply` appears once with the commands; a new hospital has a table (`inspect hospital`: `no_table` gone).
Open: ConstructSplint is not an order economy manages (the command is the player's); crutches, plaster and soap are not asked for; a dry spell that follows more than 3 days of water is a new episode as before.
