# BUG-384 hospital: 0 sites without a fortcore, 7 hurt
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3 Yawninggilt y375, `runs/run-16c/FR-BUGS.md`), main ec9bd8e
Module: `dfpilot/bp/rooms.py`, `dfpilot/bp/sites.py`, `dfpilot/plan.py`, `dfpilot/cmd.py`

## Actual
`bp sites hospital` 0 sites in a fort without a dug fortcore; 7 hurt citizens, a patient's thirst up to 23,500 and no hospital.

## Root cause
Every room template (`rooms.BUILD`) hangs on the dug public Z4 floor (`sites.rank`: `room sites need the fort manifest with
zones.Z4`); BUG-356 (shops) and BUG-368 (depot) gave the startup pieces a surface variant, the hospital had none.

## Fix
- `rooms.hospital` with `surface=1` (`_surface_hospital`): a 7x5 block on open surface floor, nothing dug, no door/burrow/well
  (the kernel's accepted water decides the site), beds, traction bench, chests, the meeting zone `location=hospital`, a manifest
  hospital room (no Z4).
- `sites.rank`: `hospital` with `surface` needs no manifest (`_surface_shops`: flat revealed floor with open sky, the citizens'
  walk group, off the keep-out tiles, nearest the snapshot middle or `--near`), then the existing `WATER_TPLS` filter keeps the
  ones within `near` of accepted water (`bp sites hospital surface=1 --fresh --near <wagon>`); `cmd.no_site_hint` names the block.
- `plan.hospital_facts` offers the surface site when the manifest has no Z4 (`fort.hosp.surface`); `propose` in the no-core
  branch drafts `hospital@S1 p.surface=1` when `water.patients > 0`, no hospital zone (`water.hosp 0`) and such a site is free
  (`hospital_surface_due`), noted `BUG-384`; the BUG-034 water gate still applies.

## Open
No accepted water (no well, no Water Source zone) still holds the hospital back; the kernel zones the scan's water by itself
(BUG-324). Once a fortcore (Kern+/Tiefe+) exists the surface hospital counts as `hospital_out` (BUG-036/131: `hospital.retire`,
a dug hospital in the core instead).

## Tests
tests/test_bug384_surface_hospital.py (6).

## Live check
i3-like: `bp sites hospital surface=1 --fresh --near <wagon x,y,z>` lists a site; `plan propose` drafts `hospital@S1 p.surface=1`
with patients lying; `bp.place` builds beds/zone; `status` hospital zone ok, patients get water.
