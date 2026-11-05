# BUG-483 `plan propose` places captives on the only hospital site
Status: fixed (offline, live-untested)
Severity: medium (a patient's thirst climbed to 31155 with no hospital site left, the player cancelled y398s3b3 by hand)
Found: 2026-11-05, Run 16b i2 Roadvises y398 (`bp sites hospital`: 1 ranked site, "taken by y398s3b3 (captives)")
Module: `dfpilot/plan.py` (`hospital_reserve`, `fit_placeable`, `place_all`), `dfpilot/cmd.py` (`Occupancy.discard`)

## Actual
The plan drafted captives (phase list) while the hospital was held back for water or came later in plan order; `place_all` / `fit_placeable` give every build the first free site in plan order, so captives (a room-class template with the same public anchors) took the one site the hospital could use.

## Root cause
Placement order is plan order (`place_all`, `fit_placeable`); nothing ranked the hospital above the defense room.

## Fix
`plan.hospital_reserve(save_dir, builds, occ, snap)`: while the fort has no hospital (no hospital project in <save>/bp, none in the manifest rooms) and a `HOSPITAL_FIRST` build (captives) comes before any hospital build of the plan, the hospital's first free site is placed into the occupancy as `reserve-hospital`, so captives only get another site (or are left out by `fit_placeable`, the note says "BUG-483: the hospital's site is kept for the hospital"; `place_all` refuses the apply with the usual no-site error). The hospital build, when it comes, drops the reservation and takes the site (`Occupancy.discard`). No hospital site at all: nothing is held. With a hospital standing or planned first nothing changes.

## Tests
`tests/test_bug482_486_f30misc.py` (4: captives left out on the only site, captives elsewhere + hospital keeps its own site, hospital standing / first, no hospital site).

## Live check
A fort with one hospital site and captives in the draft: `plan propose` / `plan check` drop captives with "BUG-483: the hospital's site is kept for the hospital" (or give it another site); `bp sites hospital` keeps its site.
