# BUG-346 farms: 0 free sites for years, though the fort's own levels are soil
Status: fixed (offline, live-untested) for soil forts; a stone fort (i4) gets the reason and the surface farm (PEACE) or trade; open: a stone fort outside PEACE
Severity: critical
Found: 2026-11-04, Run 15 (i2 Guildcleans y381 Pop 74-100, i1 Inkintense, i4 Drillchamber y395, i3 Earthboat)
Module: `dfpilot/bp/sites.py` (_rooms, the BUG-257 soil rule), `dfpilot/cmd.py` (sites cache, no-site hint);
`lua/dfllm/snapshot.lua:1317` (soil marks on revealed floor only) unchanged

## Actual
- i2 Guildcleans y381: AUTO_FAIL x11 `only 0 free sites for farms` (plots=4, 0 ranked) at pop 74, food 281 d falling.
- i1 Inkintense: `only 0 free site(s) for farms` again and again, famine, fort lost (pop 43 -> 4).
- i4 Drillchamber y395: fortcore@S1 done, `bp sites farms --fresh` still 0 sites, the hint said `rooms open from the dug Z4 floor
  of the fortcore ... snapshot may predate its dig`.

## Evidence
Offline on the newest sites snapshot + fort manifest of each run (scratch script, read only):
- Room sites `farms {}` / `{plots:1}`: 0 in all four forts, while `soil_levels` (soil marks on the fort's revealed Z4 floor):
  i2 z128 499/499 soil (z125 0/1267), i3 z138 583/583, i1 z131 339/525, i4 z142 0/939, z139 0/1368 (stone).
- Every snapshot soil mark is a `.` floor tile (i2 7587/7587, i4 8000/8000, i1 7518/7518): snapshot.lua scan_span marks soil
  only `if soil and c == '.'`; the rock (`#`) and hidden (`?`) tiles a farm room is dug from never carry one.
- sites.py `_rooms` (BUG-257): `if soil_pts and 2 * s < area: continue`, with s = soil marks under the plot tiles: 0 for any
  undug room as soon as the surface has soil marks (always), so every room site was refused.
- After the fix: i2 `soil 35/35 plot tiles (35 by the soil level)` at 75,84,128 (plots 1); i1 3 sites z131 (70/70 at plots 2);
  i3 z138; i4 still 0, `farms: no soil level in the fort (soil on its dug floor: z142 0/939, z141 4/8, z139 0/1368); farm plots
  need soil ...: a surface farm (p.surface=1, in PEACE) or trade for food`; its surface sites (plots 1) exist.

## Cause
sites.py:760 (BUG-257 rule, 14ff5a3) counted soil marks under undug plot tiles; the snapshot only marks revealed floor, so the rule
refused every underground room. The cached ranking (cmd.py `_sites_cache`, keyed by snapshot, params, manifest and water)
would also have kept the old `[]` on the same snapshot after a code update.

## Fix
- sites.py `soil_levels(snap, manifest)`: per level the fort's revealed Z4 floor tiles and how many are soil-marked;
  `soil_level_set`: >= SOIL_LEVEL_MIN (8) soil tiles and at least half the level's fort floor. On a soil level the undug plot
  tiles count as soil (`soil s/area plot tiles (k by the soil level)`); a stone level keeps the BUG-257 refusal.
- `farm_soil_why`: the levels' soil for the no-site error (cmd.farm_hint replaces the fortcore hint for farms with 0 ranked).
- `RANK_V` (2): cmd's sites cache carries it (`rv`), a cache of older rules is ranked again.
- follow's farm_tries (BUG-340) already falls back to fewer plots and, in PEACE, to the surface farm; no change.

## Tests
- tests/bp/test_bug346_farm_soil_level.py (5; all fail on 14ff5a3): room sites on a soil level with floor-only marks, a stone fort
  has none and names why, a level with little soil floor is none, a cache without `rv` is ranked again, the farm hint.
- tests/bp/test_sites_farms_soil.py (BUG-257) unchanged and green.

## Live check
- `dfllm bp sites farms --fresh` in i1/i2/i3: sites on the soil level with `(N by the soil level)`; follow's farms request
  places a room (plots 4 .. 1), the farms project digs and `build` lays plots (no `build_lost missing p`).
- i4: `bp.place farms` error ends with `farms: no soil level in the fort ...`.

## Open
- A soil level judged by the fort's floor may change layer within the room (biome edge): then the plots that land on stone
  end build_lost, and runner's BUG-257 rule parks it (lost for good) and follow places farms elsewhere.
- A stone fort outside PEACE has no farm (surface farms only in PEACE, BUG-302); muddy floor by irrigation is not done (risky).
- Soil wall tiles are not marked by the snapshot; a fort with only stone floor dug inside a soil layer's level is not seen.
