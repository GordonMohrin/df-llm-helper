# BUG-142 A manifest station on a wall tile: the soldiers never reach it, on_station 0 of 8 blocks siege_release and bridge_stuck
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: high (wrong decision: the lone-intruder release and the BREACH fallback never fire)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/military.lua (`pick`, `note_pick`, `posture_station`)

## Actual
Squad 105 had one `squad_order_movest` to 48,40,127 and its 8 members were spread over the map; military kpi soldiers 8, on_station 0.
The verifier read the tiles: stations.b2 48,40,127 is a StoneWall (walk group 0), gallery 64,47,130 a SoilWall; to the walkable 48,44,127
6 of 8 arrived. `siege_release` (BUG-112) and `bridge_stuck` (BUG-114) need half the soldiers at their stations.

## Cause
`pick()` and `posture_station()` accepted a manifest station on any tile; a wall was also the fallback (`r.first.pos`).

## Fix
`military.no_floor`: a revealed station tile that is a wall (`#`, `S`, `C`), fortification, tree or open space (snapshot.tile, fair play:
a hidden tile is no evidence) is moved to the nearest revealed plain floor clear of the bridges (the BUG-032 search), STATION_MOVED (B)
`why wall`: `station b2 X is no floor (#): moved to Y`; a wall is never the fallback station.

## Tests
`tests/lua/test_stations.lua` BUG-142 (fails on dec5132: the squad is ordered onto the wall); the test of stations clear of every footprint
now allows one tile read per station.
