# BUG-502 `bp sites hospital` / `aqshaft` list nothing while an explicit anchor is accepted; aqshaft errors name no holder; a finished shaft keeps its whole plan
Status: fixed (offline, live-untested)
Severity: high (a hospital placed by anchor stalled 881 days; aqshaft columns were hidden for years)
Found: 2026-11-05, Run 16a i1 Basementflew y395-y398 (`runs/run-16a/FR-BUGS.md` "hospital: `bp sites hospital` leer, aber expliziter Anker ... angenommen", "bp sites aqshaft: ... nennt keine Halter"; runtime kern.log "hospital ... stale: set aside 485 ... 1037 d ... door 112,101,131: nothing stands", cli.log 1478-1479, bp/c1a1ad43129a01f301.json, read only)
Module: `dfpilot/cmd.py` (`_place`, `anchor_checked`, `aq_top_ok`, `_free_of_projects`, `occupancy`, `aq_bottoms`), `dfpilot/bp/sites.py` (`rank` error, `_near_water`)

## Actual
- `bp sites hospital`: "no site within 30 tiles of accepted water (nearest candidate 65,51,129 is 56 tiles from it)", but `bp.place tpl=hospital site=A112_100_131_0` was accepted (bp/c1a1ad43129a01f301.json: surface 0, z131 = the open surface, room bbox 109-115,102-106). The project dug a "room" into surface soil and stood 881 days at 30 % ("door 112,101,131: nothing stands").
- `bp sites aqshaft`: "all 891 candidate site(s) lie on or beside placed projects" with no holder, while `bp.place aqshaft site=A50_20_129_0` went through.
- The old aqshaft c1a1ac68a2 (done at z125 after 2 of 16 planned levels) kept all 16 levels reserved ("overlaps project").

## Root cause
- `cmd._place`, label `A<x>_<y>_<z>_<rot>` (line ~1990): `emit_at` + `occ.clash` only. The ranking's candidates come from `sites._rooms` (public Z4 floor, rock behind the walls, `_near_water`, bp/sites.py ~941-1000) and `_free_of_projects` (aqshaft: top tile not on a placed room's floor); none of that ran for an anchor.
- `cmd._free_of_projects.free`: the `top` test and an `emit_at` failure returned False without adding a holder (`held` stayed empty: the message printed no id).
- `cmd.occupancy`: a finished aqshaft reserves `footprint(doc)` = all planned levels, although `AQ_PASS_DONE bot` ended it.

## Fix
- `cmd.anchor_checked` (A-label placement): aqshaft: the top tile test `aq_top_ok` (one function, also used by the ranking); a room template with accepted water in the state (hospital): `rank_sites(where={"at": anchor})`, whose error says why no site stands there and where the nearest valid one is. `column_checked` (BUG-433's rules) now also runs for an aqshaft anchor label. No snapshot / no water state: unchecked as before.
- `_free_of_projects` counts per reason (clash / top on a placed room's floor / cannot be emitted + the emit message) and the owner of the top tile joins `held`; `sites.rank` prints "N touch a placed project's tiles; M start on the floor of a placed room ...; K cannot be emitted there (...)" and up to 6 holder ids. `aq_top_ok` also lets a shaft start on an aqshaft or explore floor (corridors).
- `occupancy`: a finished aqshaft (AQ_PASS_DONE `bot`) holds only the levels z >= bot (`aq_bottoms`).
- `sites._near_water`: the "no site within N tiles" error points at `bp sites <tpl> surface=1` and says an explicit anchor must pass the same test.

## Tests
`tests/test_bug501_505_f31.py` (5: `aq_top_ok`, the anchor on a room floor refused with the holder, the ranking's holder and reason, a finished aqshaft releases its unused levels, a hospital anchor the ranking would not offer is refused / unchecked without water state, the near-water text).

## Live check
`dfllm bp sites aqshaft` with every column held: the message names the project ids and the test. `bp.place tpl=hospital site=A<x>_<y>_<z>_0` far from accepted water: ERR "hospital@A..: not a site the ranking would offer (BUG-502): ...". After an AQ_PASS_DONE the shaft's lower levels no longer block `bp sites aqshaft`.
Open: the ranking itself is unchanged (a hospital still needs the fort's Z4 floor or `surface=1`); the hand-placed anchor is now refused, not offered.
