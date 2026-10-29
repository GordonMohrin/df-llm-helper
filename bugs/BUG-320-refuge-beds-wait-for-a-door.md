# BUG-320 a refuge_beds project waits months for the door of its doorway
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15b (Earthboat, live, round 3)
Module: `dfpilot/bp/rooms.py` (refuge_beds), `dfpilot/bp/validate.py` (OPEN_ROOMS)

## Actual
Earthboat y384-y385: project y384s1b2 (refuge_beds n=2 at 58,86,132) dug (`dig done`) and then stood at `build` for months:
PROJECT_BLOCKED `stalled at build; waits: Door 59,86,132: job 282763 suspended by buildingplan: waits for door x1 (1 free, 5 ordered);
Bed 60,88,132: ... waits for bed x1 (12 ordered)`. The refuge stayed 5 beds short and plan check kept asking for beds.

Root cause: `dfpilot/bp/rooms.py:399`: refuge_beds dug its room with `_box(..)` and its default door, so every refuge dormitory needed a
door item in its doorway, although the room is dug into rock and opens only into the refuge (the refuge's hatch and doors close it;
the door closed nothing more and was one more item the refuge waited for).

## Fix
refuge_beds digs its doorway and builds no door (`_box(..., door=False)`, as the FR-69 drink store); validate's closure check treats
it as an open room (`OPEN_ROOMS`), as refuge_drink. The beds still wait for bed items (the orders, not this package).

## Tests
`tests/bp/test_bug319_320_refuge_rooms.py::test_refuge_beds_build_no_door` (fails on 1d17c7e: a `d` in the build stage); golden
`tests/bp/golden/refuge_beds.json` regenerated (materials bed only); the refuge_beds emit/audit tests still pass (no new way in).

## Live check
New refuge_beds projects have no Door in their PROJECT_BLOCKED / `inspect projects` waits. The running y384s1b2 keeps its old document
with the door: `bp.cancel` it once a new refuge_beds is placed, or wait for the door. Uncertain: why buildingplan did not take the 1 free
door (builders/orders, another package).
