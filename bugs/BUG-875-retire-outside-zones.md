# BUG-875 Drink jobs kept going to the Water Source zone at the river although the fort had water inside: seven citizens drowned at the bank
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: #6573 'citizen 29328 drowned at 118,82,143 (water 7/7, river)'; 7 of 37 DEATH citizens DROWNED on the river strip x100-160 y73-114 z143; kernel zone 17715 at 101,95,143 painted at tick 150022783.

## Root cause
No code retired a kernel-painted outside zone once an inside source existed (`water.lua` only painted: `M.zone_found`; the player removed zone 17715 by hand).

## Fix
`act.water_zone_remove(id)` (one Water Source zone, only named `dfllm-water`, never the open zone sheet; contract owner water) and `M.retire_outside`: after `water.retire_days` (3) days in a row with an accepted inside source and every hospital zone served by an inside source within `near`, ONE kernel-painted (dfllm-water) zone outside the fort (no burrow, no Z4 box) goes per run; event WATER_OUTSIDE_RETIRED (B). Zones with another name (the player's) are never touched; with no inside source nothing goes; `water.outside_retire` false switches it off.

## Tests
`tests/lua/test_bug871_877_water.lua` (BUG-875: retired after 3 days, a player-named zone kept, no inside source: kept).

## Live-Erwartung
On a fort with an inside accepted source for 3 days: kern.log 'Water Source zone N ... retired' and WATER_OUTSIDE_RETIRED for each kernel-painted outside zone (PROMISED). That fewer citizens then go out is NOT promised: DF also takes drink jobs to water the player zoned.
