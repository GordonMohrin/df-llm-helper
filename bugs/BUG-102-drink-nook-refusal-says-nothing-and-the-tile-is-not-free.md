# BUG-102 The drink nook of a critical mood is refused with "no free floor within 3 tiles": no reason, free-looking tiles that are not free, and a quickfort refusal nobody reads
Status: fixed in the L1 commit (offline, live-untested): the refusal names its reasons in counts, a tile is judged the way
quickfort's place mode judges it, a nook quickfort refuses is skipped and the next site is queued (FR-82 widens the search for a
critical mood)
Severity: high (a strange-mood dwarf died of thirst behind a message that could not be acted on)
Found: 2026-10-23, Run 14 (Trussroads), game session note 73 (unit 35427, thirst 64976/75000, MOOD_CRITICAL, workshop at 29,118,126)
Module: `lua/dfllm/care.lua` (`nook_site`, `mood_relief`, `occ_index`), `lua/dfllm/runner.lua` (`apply`, `finish`, `nook_state`),
`lua/dfllm/snapshot.lua` (`tile`, `item_tiles`)

## Actual
`mood_relief` answered `no free floor within 3 tiles of the workshop for a drink nook` for a dwarf at thirst 64,976. A read of the
tiles by hand (`getTileType`, `findAtTile`) showed free floor (29,117,126 `FLOOR`, no building). A quickfort `#place` of a 1-tile
stockpile there said `Stockpile tiles skipped (tile occupied)` for the three nearest tiles (29..31,117,126); 4-5 tiles further
(28,117 / 29,116 / 32,118 / 27,117 / 26,117) it worked. The text gave no reason, the search stopped at 3 tiles for a dwarf who had
hours left, and nothing could tell the player which of the two (the kernel's check or the by-hand read) was right.

## Cause (proven from the code at 3045b94; what stays open is under "Not decided offline")
1. **The refusal text is one fixed sentence.** `mood_relief` (care.lua:1752-1755) sets `rec.nook_why` to the constant
   `'no free floor within 3 tiles ...'` whenever `nook_site` returns nil; `nook_site` (care.lua:1707-1736) returns nil for every
   reason alike (no holder rect, every tile occupied, wall, hidden, unreachable) and keeps no count. The radius 3 and the 40-tile
   probe cap are constants (`MOOD_NOOK_R`, `MOOD_NOOK_PROBES`, care.lua:1706) with no config and no widening, critical or not.
2. **The tile check is not quickfort's.** `nook_site` accepts a tile when `occ_index` (care.lua:1685-1700: the rectangles of
   `buildings.other.IN_PLAY`, `ANY_ZONE`, `STOCKPILE`) does not cover it, `snapshot.tile` says `c == '.'`, `bld == ''`, `dig == ''`
   and `reach_ok` (care.lua:997-1001, `snapshot.reach` -> `dfhack.maps.canWalkBetween`) agrees. DFHack's own rule for a
   stockpile tile (`scripts/internal/quickfort/place.lua:29-43` `is_valid_stockpile_tile`, counted in `building.lua:517-559` and
   reported as `place_occupied` = "Stockpile tiles skipped (tile occupied)") is: not hidden, `occupancy.building == 0` and a shape in
   FLOOR, BOULDER, PEBBLES, TWIG, SAPLING, SHRUB, RAMP, STAIR_*. The two differ in three places the code proves:
   - `snapshot.lua:68-72` (`SHAPE`) draws `BRANCH`, `TRUNK_BRANCH`, `BROOK_BED` and `BROOK_TOP` as floor `'.'`; place mode refuses them.
   - `snapshot.classify` (snapshot.lua:177-204) treats `occupancy.building == Planned` as free (`b ~= occ.None and b ~= occ.Planned`);
     place mode refuses any non-zero value. `M.tile` (snapshot.lua:251-278) did not return the occupancy at all.
   - `M.tile` drops the plant (`classify` returns it as the 4th value) and the kernel never looks at items on the floor
     (`snapshot.items_at` exists, `nook_site` does not call it): a tile with a shrub, a sapling or loose items was a "free" nook.
3. **The walk anchor is the workshop's first tile.** `nook_site` asks `reach_ok(tile, {rc.x1, rc.y1})` (care.lua:1731-1732): a tile
   of the workshop's own footprint, not the dwarf and not an open tile beside the workshop. Whether that tile has a walk group is
   not proven (see below); if it has none, `canWalkBetween` is false for every tile and the nook can never be found.
   (Note 73 cites "care.lua:1649-1656" for this check; at 3045b94 it is care.lua:997-1001 and the call at :1731.)
4. **The quickfort answer is never read for a nook.** `runner.apply` (runner.lua:1516-1627) reads `build_unsuitable` for a
   plug, `dig_invalid_tiles` for dig and `build_unsuitable` for build; for `place` it reads nothing. `act.quickfort`
   (act.lua:1417-1421) already returns every stat as a number (`place_designated`, `place_tiles`, `place_occupied`). A `mood_drink`
   project whose tile quickfort skipped therefore finished normally (`finish`, runner.lua:1829), `mood_relief` stored
   `p.nook[sid] = {txt = 'drink nook queued at ...'}` for the rest of the mood (`if type(done) == 'table' then return done.txt`)
   and told MOOD_RISK/MOOD_CRITICAL the nook stood. No stockpile existed and nothing tried another tile.
5. **The retry is a flat hour.** `rec.nook_try` plus `mood_nook_retry` (3600 ticks) was the only gate: a critical mood waited out
   the hour whatever the thirst did.

## Fix
- **The reason in counts** (care.lua `nook_site`, `nook_text`): every candidate tile gets one verdict, in the order building / zone
  (occ_index) -> quickfort-refused (this mood) -> building (`bld` or occupancy non-zero) -> wrong shape (not `.`, or a shape place
  mode refuses, or hidden) -> designation -> plant -> item (new `snapshot.item_tiles`, one pass over the map blocks of the search
  box) -> unreachable. The text is `no nook within 6: 9 occupied, 4 unreachable, 2 wrong shape, 3 too far` (fixed vocabulary;
  occupied = building, zone, designation, plant, item, refused; the breakdown by kind is in kern.log), at most 80 bytes, so
  MOOD_RISK and MOOD_CRITICAL (`d.nook`) stay within 200. `too far` = candidates inside the radius that the read budget
  (`mood_nook_probes` 40 full reads per step; walls, buildings and zones around cost no read) did not reach.
- **Quickfort's rule** (snapshot.lua): `M.tile` returns `shape`, `plant` and `occ`; `nook_site` takes only floor of a shape place mode
  takes, with `occupancy.building == 0`, no plant, no item, no designation, not in a cavern.
- **Walk anchor:** a tile is reachable when the workshop's first tile OR the moody dwarf's own position walks to it (never worse than
  before).
- **The refusal comes back** (runner.lua): a `mood_drink` project whose place call designated no stockpile (`place_occupied` > 0 or
  `place_designated` 0) keeps `P.refused = 'x,y,z'` and says so in kern.log and in its PROJECT_DONE text; `runner.nook_state(id)`
  answers `pending` / `refused` / `placed` / nil. `mood_relief` asks it while the nook is not confirmed: on `refused` it drops
  `p.nook[sid]`, remembers the tile in `rec.bad` (12 at most, gone with the mood) and searches again at once for the next site,
  at most `mood_nook_tries` (4) nooks per unit and game day; beyond that the text says `quickfort refused the drink nook at x,y,z
  (tile occupied)` until the next day.
- **Cadence:** the same reason for the same unit is logged once (`rec.nook_log`); the search itself still waits `mood_nook_retry`;
  the events keep their own cadence (util/cadence) because the nook text is no cause token.
- A relief that did work is unchanged: same tile order, same text `drink nook queued at x,y,z (mdrN)`, once per mood, only in
  PEACE/RECOVERY, `mood_nook` false switches it off. An old state (a mood record without the new fields, a `p.nook` record without
  `ok`) works as before; a project the list no longer holds answers nil and the record stays.

## Not decided offline
- **What made the three nearest tiles (29..31,117,126) "occupied" for quickfort.** The code proves the kernel ignored items, plants,
  planned occupancy and non-floor shapes; it cannot say which one it was. Read-only, per tile: `df.tiletype.attrs[
  dfhack.maps.getTileType(pos)].shape` (as a name), `dfhack.maps.getTileFlags(pos)` -> `occupancy.building` (a `df.tile_building_occ`
  value), `dfhack.buildings.findAtTile(pos)`, the items of `dfhack.maps.getTileBlock(pos).items` with `pos` equal, and the next
  MOOD_RISK/MOOD_CRITICAL text, whose counts say which class the kernel now sees.
- **Whether the workshop's first tile has a walk group** (`dfhack.maps.getWalkableGroup(corner)` of the claimed workshop and of a free
  tile beside it). If it is 0, every nook before this change was refused as unreachable; the dwarf-position anchor then decides.
- Whether a moody dwarf drinks from the nook at all stays the open question of BUG-063.

## Tests
`tests/lua/test_care_nook.lua` (15; the counts text, the read budget, item / plant / designation / planned occupancy, zone and
stockpile, the dwarf-position anchor, the quickfort refusal re-pick and its daily bound, the log cadence, an older state),
`tests/lua/test_runner_nook.lua` (the refused / placed / unknown states), `tests/lua/test_snapshot_nook.lua` (`shape` / `plant` /
`occ`, `item_tiles`), `tests/test_l1_nook.py` (config ranges and contract text); `test_care_b3.lua` follows the new wording. All new
tests fail on 3045b94.
