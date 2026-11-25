# BUG-855 Logs built into walls and buildings counted as stock ('wood 0 usable of 361'), the raw dump called them unwalkable, and every new wall took more logs
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i1 Diedplank y384-y385 (records 204 -> 256 -> 285, unwalkable 198 -> 210 -> 239 with every build), i4 Girderroots y394 (365 records, 0 free: forbid 5, in_building 14, other_walk_group 10, unwalkable_tile 336; every sample `tile=C/WALL/CONSTRUCTION group=0 flags=[construction]`).
Module: `lua/dfllm/economy.lua` (`classify` skip branches, `ZERO` / `wood_built`, state `stock.woodb`, `M.wood_cancel`, `M.wood_guard`, `T.jmake`), `lua/dfllm/dfraw.lua` (`R.REASONS`, `R.itemscan`, `R.items`), `dfpilot/brief.py`, `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`, config `economy.wguard`

## Root cause
The census already SKIPPED items flagged `construction` / `in_building` but counted them in `woodt` ('usable of M'), so the status read 'wood 0 usable of 361', and the raw dump (`dfraw`, which has no `construction` reason) put every built log under `unwalkable_tile` (their tile is a wall, group 0): a walk problem that does not exist. The kernel itself never picks a log for a construction: walls, seals, depots and buildings take what buildingplan's global material settings allow (blocks, boulders, logs; `M.bm_route`, `M.wall_alt`, `T.jmake` switch them); both logs and boulders were on, so every new wall took logs while the fort had none to spare.

## Fix
- Census: a skipped log with the flag `construction` or `in_building` is `wood_built`, not `wood_skip`; state `stock.woodb`; `woodt` counts only loose logs. Status: `wood 0 (25 loose unusable; 336 built in)`; without built-in logs the NEU4 text `wood N usable of M` stays. `wood_cancel` ('Needs logs') names the built-in count.
- Raw dump: reason `built` (flag `construction`, before the tile reasons; a built log is no `unwalkable_tile`) and the line `built into constructions or buildings: N (no stock: built a, in a building b)`.
- `M.wood_guard` (T.jmake, every run): usable wood below `wguard.low` (40) and at least `wguard.stone_min` (8) free boulders plus blocks and DF not refusing stone -> `buildingplan set logs false` (one kern.log warn), so the kernel's walls, seals and buildings take stone and blocks; back on at `wguard.high` (80) logs or when the stone is gone or refused (`p.bplog`). Left as they were: the treeless path (`M.treeless`: wood floors, caravan wood wants, autochop target), the logs DF's own jobs take, doors and furniture orders (`wood_orders` already switches to stone below 20 boulders).

## Tests
`tests/lua/test_bug855_wood.lua` (4): 336 built + 14 in buildings + 25 loose: `wood_built 350`, `woodt 25`; dfraw `built=30`, `unwalkable_tile=3`, the dump line; the guard goes off, on, does not act at wood 60, not without stone, goes back on when the stone is gone. `tests/lua/test_neu4_cancel.lua` (the i1 census: 5 in-building logs are built-in now). `tests/test_neu7_vorrat.py` (status text).

## Live-Erwartung
1. i1 and i4 `status`: `wood 0 (N loose unusable; M built in)` with M about 200-350 (PROMISED: the census reads the flag DF sets on built-in items; every Run 17 sample carried `flags=[construction]`).
2. `why items:logs --raw`: `built=...` instead of `unwalkable_tile=336`, plus the line 'built into constructions or buildings'.
3. kern.log `buildingplan logs off: N usable logs (below 40), M free boulders and blocks` once where logs are short and stone is free (EXPECTED on i1, i4); `buildingplan logs on again` when wood reached 80 or the stone ran out. NOT promised: that logs lying on tiles without a walk group become usable; that new logs arrive (caravans, trees); wooden walls already built stay.
