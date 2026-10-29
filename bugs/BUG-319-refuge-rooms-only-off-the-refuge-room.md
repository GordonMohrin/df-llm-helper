# BUG-319 refuge beds and drink store find no site once the refuge room's walls are taken
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15b (Earthboat, live, round 3)
Module: `dfpilot/bp/sites.py` (refuge_ext, _anchor_tiles, _rooms)

## Actual
Earthboat y385 (pop 83, P5): `plan propose` -> ERROR `Tiefe+ has 16 beds < 21 ... add refuge_beds n=3`; adding it -> check ERROR
`only 0 free site(s) for refuge_beds`; `bp sites refuge_beds --fresh` -> none. `bp.place refuge_drink` (y384 autumn) -> `no site for
12 barrels (5x3) beside the refuge room 52-58,78-86 z132, not even a 3x1 store`. On the snapshot (c1a188ba925ebbf901) the 7x9 refuge
room has a room on every wall: refuge_beds 50,76-82 (west), 52-58,76 (north), 51-57,88 (south), the drink store 60-62,79-81 (east)
and y384s1b2 at 58,86; behind those rooms lies only unknown rock.

Root cause: `dfpilot/bp/sites.py:576` (`_anchor_tiles`): a refuge-level template anchored only on the floor of the fortcore refuge room
(`refuge_rooms`), so the refuge could never grow beyond the rooms that fit along that room's four walls.

## Fix
`sites.refuge_ext(manifest)`: the manifest's refuge-level rooms (`rooms.REFUGE_LEVEL`: refuge_beds, refuge_drink) on the refuge level.
Their floor is an anchor too (they lie in the refuge burrow and open only into the refuge; the new room's footprint and wall ring stay
rock or unknown, so it adds no way in). Such anchors rank after the refuge room's own (`REFUGE_EXT_PEN` 20) and say `dug off a
refuge-level room (BUG-319)` in `why`. The same holds for a cistern with level=refuge.

## Tests
`tests/bp/test_bug319_320_refuge_rooms.py`: the big fort with refuge rooms placed until the refuge room has no anchor of its own;
refuge_beds and refuge_drink then rank sites on those rooms' floor, build without errors and pass the audit (refuge_sep, no bypass)
(fails on 1d17c7e: no site); the refuge room's own anchors rank first; refuge_ext lists only refuge-level rooms on the refuge level.

## Live check
Offline on the live Earthboat folder (read-only, snapshot c1a188ba925ebbf901): refuge_beds n=3 and n=5 rank S1 50,78,132 rot1, S2
54,76,132 rot2, S3 53,88,132 rot0; refuge_drink n=12 ranks S1 50,78,132 rot1 (before: none / ValueError). Live: `dfllm bp sites
refuge_beds --fresh` names such sites with `BUG-319` in the line; after the dig, `inspect refuge` beds rise and the audit keeps
`refuge_sep`. Uncertain: whether the haulers and sleepers path through a bed room into the next one as the topology says (beds are
walkable in DF).
