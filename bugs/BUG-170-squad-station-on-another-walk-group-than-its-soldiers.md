# BUG-170 A squad station on another walk group than its soldiers: the BUG-142 move put b2 behind the raised B2, on_station 0 of 8
Status: fixed in the fix2-stations commit (offline, live-untested)
Severity: high (wrong decision: the lone-intruder release (M3-release) and the BREACH fallback bridge_stuck (M3-breach-stuck) never fire)
Found: 2026-10-29, live test round 2 instance i3 (E:/DF-test3, region2-site90 Trussroads y722), confirmed by the skeptic (BUG-142 retest, NEW1)
Module: lua/dfllm/military.lua (`pick`, `reloc`, `note_pick`, `posture_station`, new `M.group_at`, `M.off_group`, `M.home_group`),
lua/dfllm/stations.lua (`S.relocate`)

## Actual
`STATION_MOVED station b2 48,40,127 is no floor (#): moved to 47,41,127` (why wall). Squad 105 got the move order 47,41,127, a floor on walk
group 2157 (renumbered 2159, 2161), a pocket behind B2 (bridge 26040), which reads raised even in PEACE. All 8 soldiers stood on group 6;
military kpi on_station 0 of 8 through ALERT, BREACH and SIEGE. The chain's alt `core` 48,44,127 and the civ stair top 48,42,130 lie on the
same cut-off group; only `melee` 55,42,130 is on group 6. `inner_chain` puts `b2` first exactly while the core bridge is up.

## Cause
`S.relocate` ok() checked bridge clearance, the inner side, stairs and the floor, never the walk group; `pick()` accepted the station itself or
its replacement without asking whether any squad member can walk there.

## Fix
`pick()` reads the main walk group of the squad it picks for (the group most living members stand on, via snapshot.groups; without a squad every
fort squad's, else the citizens'). A station on another known group (hidden = -1 never counts as evidence) is skipped like a wall: it moves to the
nearest revealed floor on the soldiers' group (`S.relocate` with `o.group`/`o.group_of`), else the next entry of the chain (alt entries too).
STATION_MOVED (B) `why unreachable` with `grp`/`home`: `station b2 X lies on walk group G, the soldiers on H (no way there): moved to melee Y`.
Groups are cached 100 ticks only (`M.GROUP_TTL`; a moving bridge renumbers them), the relocation cache is keyed by the group and re-checked.
The b2-first chain while B2 is up stays (right when the soldiers are inside the core); with the soldiers outside it now falls through to melee.

## Tests
`tests/lua/test_stations.lua` BUG-170 (three tests; each fails on b805745: relocate ignores the group, BREACH orders the squads to 51,63 on the
other group, no move to the reachable floor and no return after the groups merge).
