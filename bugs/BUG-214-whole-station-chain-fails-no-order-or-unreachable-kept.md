# BUG-214 The whole station chain fails: no station order, or the unreachable first station kept
Status: fixed (offline, live-untested)
Severity: high (wrong decision: the squads get no station or one nobody can walk to, on_station 0-3 of 8 in BREACH and SIEGE)
Found: 2026-10-29, live test round 4 (E:/DF-test4, region2-site90 Trussroads y732-733), retest of BUG-170, confirmed by the skeptic
Module: lua/dfllm/military.lua (`pick`, `reloc`, `note_pick`, `posture_station`, new `M.kern_box`, `M.kern_floor`),
lua/dfllm/stations.lua (new `S.relocate_box`)

## Actual
With B2 raised the chain b2, core, z4, melee failed entry by entry: `b2 48,40,127` a wall, `core 48,44,127` on walk group 0, melee
55,42,130 on group 1507 behind B2, the soldiers on group 1. #35061 'station b2 48,40,127 is no floor: no revealed floor near it and no
other station of its chain: no station order' (kpi off {nost: 8}, on_station 0 of 8 for 19+ days); #34581 'station melee 55,42,130 lies on
walk group 1507, the soldiers on 1 (no way there): ... kept' (an order 5 of 8 soldiers could not follow, on_station 3 of 8 in SIEGE).
The text claimed 'no other station of its chain' after all four entries had been tried.

## Cause
`reloc` searches only `S.SEARCH_R` = 8 tiles around each entry, so no floor on the home group was found across the raised B2. `pick()`
had no fallback once the chain was used up; `posture_station` then returned `r.first.pos` for an unreachable first entry ('kept') and
nil for a wall. `note_pick` used a fixed text.

## Fix
`pick()` (with `o.fallback`, set by `posture_station` only: not for `safe_pos` or `restation`) records why each entry failed
(`b2 wall, core group 0, z4 none, melee group 1507`). When the chain failed on a wall or the walk group it takes the nearest floor on the
soldiers' group within 3 * SEARCH_R (24) of the first entry (via `wide`), else the nearest revealed floor on a Kern+ tile on that group
(`S.relocate_box` over the box of the burrow's blocks, `dfhack.burrows.listBlocks`, its level first, at most 4,000 probes, cached
RELOC_TTL; via `kern`, station `Kern+`). STATION_MOVED `why fallback` with `via`, `home`, `tried`. `posture_station` never returns the
first entry's position when it is a wall or on another group: no station order instead, and the event text names the failed entries.

## Tests
`tests/lua/test_stations.lua` BUG-214 (three tests: relocate_box, the wide fallback naming every failed entry, the Kern+ fallback and no
order instead of the unreachable first entry); each fails on 5e9e719.

## Live check
Raise B2 with the soldiers outside the core and force BREACH: `dfllm events --type STATION_MOVED` shows `fallback` (via wide or kern)
naming `b2 wall, core group 0, ...`, the squads screen shows the new station, `dfllm status` on_station rises to at least half.
