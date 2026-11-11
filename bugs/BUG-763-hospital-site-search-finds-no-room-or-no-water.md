# BUG-763 hospital placement finds no site: no 7x5 room fits, water too far
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16a i1 Basementflew y525-y534: `bp.place hospital` "no valid site (1201 anchors, 4804 placements: 3842 no open door tile, 962 room meets rock/wall/liquid, 0 fit; nearest water zone 23 tiles from Tiefe+)"; patient 27129 died of thirst with the water 91 tiles away
Module: `dfpilot/bp/sites.py` (`rank`, `_rank_hospital`, `_near_water`, `_rooms_funnel`, `_misses`), `dfpilot/bp/rooms.py` (`hospital`), `dfpilot/cmd.py` (`site_params`)

## Actual
The only hospital room was the 7x5 block dug from a public Z4 floor tile; when no such block fits the rock (or none lies within `water.near` of accepted water) the player had no hospital at all, and the refusal named counts, not the nearest miss.

## Root cause
`sites.rank` had one room size and one water radius, no fallback; `_rooms_funnel` counted placements but never the best near-miss.

## Fix
Hospital param `compact` (0/1): a 5x4 room (up to 5 beds in one row, well and pond inside it, table, bench, chests as before). `sites.rank` for a hospital with accepted water (`water`) goes through `_rank_hospital`: the 7x5 room near water, then the compact room near water; each compact site carries `compact` = 1 and says so in `why`; `cmd.site_params` puts it into the document at place time (p.compact given stays; `compact=0` forbids the fallback). Param `carry` (0/1, asked for: `bp sites hospital carry=1`): also sites up to `HOSPITAL_CARRY_MAX` (80) tiles from accepted water, marked `water.carry` = 1 and "WATER CARRIER ROUTE" in `why` (the caregivers carry the drink; nearest site first). The refusal tells the player about `carry=1`. `_rooms_funnel` adds, when nothing fits, how many no-door placements have a room that fits (door tile is open floor) and the nearest miss (anchor, rot, blocked tiles). The compact room obeys the same wall-ring and liquid rules as the 7x5 room (no liquid in or above its rects, nothing dug under wet tiles).

## Open
The carrier route is opt-in: `plan.hospital_water` and the kernel's `served` (water.lua) still use `water.near` (30), so a far hospital is flagged by the plan check and its zones are removed by the kernel when a patient is over the thirst limit (BUG-034); the caregivers' bucket delivery is the existing fallback. The plan's own hospital draft does not carry `compact` in its params (the place path applies it from the site).

## Tests
`tests/test_bug763_hospital_site.py` (the compact plan geometry; compact fallback with `compact` in the site and in `cmd.site_params`; far well refused with the `carry=1` hint, ranked with it; the near-miss text). `tests/test_bug722_sites_reason.py`, `tests/test_hospital_sites.py`, `tests/test_hospital_water.py`, `tests/test_bug384_surface_hospital.py` pass unchanged.

## Live check
`dfllm bp sites hospital --fresh` on Basementflew: a compact site with "compact room 5x4" (or the refusal with a nearest miss); `bp.place hospital` takes it.
