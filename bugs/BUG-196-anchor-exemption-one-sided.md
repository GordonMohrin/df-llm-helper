# BUG-196 Occupancy anchor exemption is one-sided: a room off the fortcore corridor blocks the core's later stage
Status: fixed (offline, live-untested)
Severity: high (every room that opened off a corridor a later fortcore stage re-emits blocks that stage for good)
Found: 2026-10-29, live test round 3, Earthboat (finding F5 point 3, skeptic): fortcore stage 3 at [100,82,140] clashed with the
workshops project c1a185e68ea2802c02 anchored at 54,81,138, which touches the stage-1/3 tile 54,80,138 at 53,81,138
Module: `dfpilot/cmd.py` (`Occupancy.clash`, `Occupancy._opened_off`)

## Actual
`clash` exempted a touch only next to the NEW document's own anchor (a room opens from an existing corridor). When the
corridor's own later stage was checked, the room's tiles beside its anchor counted as a clash.

## Fix
The exemption holds both ways: a touched tile of project P that lies next to P's anchor does not clash when P's anchor is on
the new document's tiles or on a tile of a skipped template (its own stages). A WET_TPLS project (cistern basin) is never
exempt; overlaps and touches away from P's anchor still clash.

## Tests
`tests/test_bug195_198_plan_place.py::test_a_room_off_the_corridor_does_not_block_the_cores_later_stage`, fails on bd27973.

## Live check
Earthboat (port 5002): `python -m dfpilot plan propose <scratch>/p.json` and `python -m dfpilot plan check <scratch>/p.json` no
longer name c1a185e68ea2802c02 for fortcore@same.
