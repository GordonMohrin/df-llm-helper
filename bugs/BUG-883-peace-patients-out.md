# BUG-883 Patients outside Kern+/Tiefe+ are reported only in a fight; a superseded hospital zone outside keeps R0 silent
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17d i4 Girderroots y418: 7 of the 18 dead were patients (east of O1, 97-99,76-84, and in the O1-B1 corridor); kern.log named the hospital zone 17956 at 83,96,144 as 'outside, superseded (BUG-131)', so R0 hospital_out stayed silent; PATIENTS_OUT (fight only) did not name them before the dying.
Module: `lua/dfllm/water.lua` (`peace_out`, `patients_out`)

## Fix
In PEACE, with a hospital zone outside Kern+/Tiefe+ (idle and superseded ones counted) and patients on tiles of neither, PATIENTS_OUT (mode PEACE, `hosp_out` = zones) is emitted once per season (`PEACE_OUT_EVERY` 100800 ticks) with the recipe 'plan the hospital inside Kern+ (hospital.retire the old zone)'. Nothing is moved; no new mechanism.

## Tests
`tests/lua/test_water.lua` (BUG-036 test extended: one PEACE report, not again within a season, fights counted as before).

## Live-Erwartung
A fort with a hospital zone outside Kern+/Tiefe+ and a patient outside: one PATIENTS_OUT 'PEACE: n of m patients lie outside Kern+/Tiefe+ ...' per season. NOT promised: that patients are moved in a siege (only a rescue does), nor a hospital inside the refuge being built.
