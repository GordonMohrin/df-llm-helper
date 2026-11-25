# BUG-875 Drink jobs kept going to the Water Source zone at the river although the fort had water inside: seven citizens drowned at the bank
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: #6573 'citizen 29328 drowned at 118,82,143 (water 7/7, river)'; 7 of 37 DEATH citizens DROWNED on the river strip x100-160 y73-114 z143; kernel zone 17715 at 101,95,143 painted at tick 150022783.

## Root cause
No code retired a kernel-painted outside zone once an inside source existed (`water.lua` only painted: `M.zone_found`; the player removed zone 17715 by hand).

## Fix
`act.water_zone_remove(id)` (one Water Source zone, only named `dfllm-water`, never the open zone sheet; contract owner water) and `M.retire_outside`. FAIL-SAFE (verifier round 2): a zone goes only when a STRONG inside source (`M.strong_inside`: accepted, wet, not an emergency well, inside the fort, water under a well >= `water.retire_depth` 2/7, and the tile on the citizens' main walk group: snapshot.far strict = false) has stood for `water.retire_days` (28 game days) IN A ROW and every hospital zone is served by a strong inside source within `near`; ONE kernel-painted (dfllm-water) zone outside the fort (no burrow, no Z4 box) per run; event WATER_OUTSIDE_RETIRED (B). A single run without a strong source (shallow spell, dry, unreachable) restarts the 28 days. The way back: `M.restore_outside` remembers each retired tile (`p.rz`) and, once no strong inside source has stood for `water.restore_days` (2), paints it again (act.water_zone, one per run, WATER_OUTSIDE_RESTORED (B)); when the tile has a zone again nothing is painted twice. Zones with another name (the player's) are never touched; with no inside source nothing goes; `water.outside_retire` false switches it off. When in doubt the outside zone stays.

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-875: retired only after 28+ days, a player-named zone kept, no inside source: kept, inside source off the main walk group: kept; second test: a dry spell restarts the clock, then retired, then unreachable inside water -> painted again on the same tile, once).

## Live-Erwartung
On a fort with a strong inside source (well over water >= 2/7 or a deep zone, inside the fort, on the main walk group) for 28 game days in a row: kern.log 'Water Source zone N ... retired' and WATER_OUTSIDE_RETIRED, one kernel-painted outside zone per run (PROMISED). If the inside water then goes shallow, dry or out of reach for 2 days: kern.log 'painted again' and WATER_OUTSIDE_RESTORED (PROMISED, offline). On i1 NOTHING is retired for now: it has no inside source (BUG-874 live check) and its stranded groups cannot reach the pit. On i4 (aquifer cistern inside, shallow about monthly) the 28-day clock restarts at every shallow spell: retirement is rare there. That fewer citizens then go out is NOT promised: DF also takes drink jobs to water the player zoned.
