# BUG-542 water.unstick triggered a hospital removal
Status: fixed (offline, live-untested)
Severity: high (BUG-539's trigger: the player's own command took the hospital zone away)
Found: 2026-11-06, the verifier of BUG-539; Run 16b i2 Brotherarrow y395 (`water.unstick unit=26367` -> "hospital zone(s) 18030 removed", then `hospital none` for 15+ days)
Module: `lua/dfllm/water.lua` (`M.stalls`, verb `water.unstick`), `dfpilot/wake.py` (`stalled_job_hint`)

## Root cause
`water.lua` `M.stalls`: `if deep or opt.force then res.hosp = stall_hospital(...)` -- the verb (`opt.force`) always ran the hospital rung, and its rounds counted toward `n >= 3` (`deep`) of the automatic ladder too: any single `water.unstick` removed the zone of every patient over `stall_dying`.

## Fix
The verb cancels the stuck job the way the kernel can (the worker off Orderlies for a run so the game posts the job anew, the Pond zone beside him) and KEEPS the hospital zone: a forced round does not set `deep` and `stall_hospital` is not called with `opt.force`; the reply ends "the hospital zone stays". The kernel's own automatic ladder (third round, or the second at a dry well, BUG-541) is unchanged. `stalled_job_hint` no longer promises a zone removal.

## Tests
`tests/lua/test_bug540_542_hospital.lua` (four `water.unstick` in a row at 60,000: no zone removed, no memory), `tests/lua/test_bug539_hospital_restore.lua` (now removes the zone through the automatic third round), `tests/test_bug540_542_hospital.py`.
