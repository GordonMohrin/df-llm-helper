# BUG-400 site ranker: 'water 1 steps' over a frozen river and across walk groups
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Mansionlauded and the first i1 fort Bachwald, `runs/run-16a/FR-BUGS.md`), main 503bb8b
Module: `dfpilot/bp/sites.py`, `lua/dfllm/snapshot.lua`, `dfpilot/schema.py`

## Actual
`bp sites fortcore --fresh` at y372 ranked S1 110,62,159 `water 1 steps` (score 1029) while `inspect what=reach` had class `drink`
empty and `inspect what=water_sources` knew one body (874 tiles, 0 with a bank, 0 with a well spot, reach 0). The fort was built
there and 13 of 16 citizens died of thirst in y372-373 (Bachwald the same way before).

## Root cause
`sites.py` `water_steps` (was line ~1462) took every walkable tile on the water's level, beside it, or ONE LEVEL ABOVE it (the brook
top over its bed) as a bank, and walked the whole movement graph without looking at the walk groups. The newest i1 sites snapshot
(`snap/c1a1a879a24329315b.json`, bbox z149-164) has 187 `~` tiles in rock banks on z158 (the 874-tile body continues outside the box)
and `.` floor on every tile of z159 above them: 297 'banks' on z159, one step from the anchor. The only thing that makes a walkable
floor sit directly over 7/7 water inside rock is ice (a frozen river or lake: the surface freezes, the water stays below); the kernel's
own scan (`water.lua scan_body`: a bank on the water's own level) found none, which is why `water_sources` said reach 0.
`snapshot.lua` knew the ice (`tt_info().ice`, used by `M.liquids`) but `classify` did not use it: the export gave an ice tile that kept
a flow the water char `~`/`w`, and no ice floor was marked at all, so Python could not tell the roof from a brook top.
Second gap: `water_steps` also counted paths through tiles of another walk group (`wg` '0'), so a count could be a way the citizens
cannot walk.

## Fix
- `snapshot.lua`: `classify` gives an ice tile no water char (its flow can linger) and returns `ice`; a `sites` export lists the revealed
  ice tiles in `ice` (`[[x,y,z]..]`, at most `CFG.ice_max` 8000). Contract: snapshot `ice?` (schema.py, CONTRACTS, appendix).
- `sites.py`: `ice_tiles`, `other_group`; `water_steps(g, water, ice, other)`: water with ice right above it gives no bank above it,
  tiles of another walk group are no bank and are not walked through. `_fortcore` and `fill_source` pass both. `_no_water` names the
  cause: `N of M water tile(s) ... lie under ice` or `... the river or lake is frozen`. RANK_V 6 (cached rankings re-rank).

## Open
- The ice cause is read from the snapshot and the scan, not from a tile read of z159 at y372 (the fort is gone): the live check below
  settles it. If z159 over the water is not ice the next suspect is a BROOK_TOP/FLOOR tile the walk test of the kernel scan refuses.
- The ranker does not know the kernel's accepted sources (only the hospital templates take `water`); it judges revealed water.
- A thaw makes the ice tiles water again at the next export; sites ranked in winter are re-ranked then (RANK_V does not cover time).

## Tests
tests/test_bug400_402_water.py (6 for 400), tests/lua/test_bug400_402_water.lua (the ice export).

## Live check
After `dfllm reload` in a fort on a river in winter or early spring: `bp sites fortcore --fresh` shows `no water reachable (... lie under
ice ...)` or a site on the unfrozen part, the snapshot file of the sites export has `"ice":[...]` and no `~` on those tiles; in summer
the same river ranks `water N steps` as before.
