# BUG-021 CUTOFF "citizens cut off from food: cause not found" fires while everybody can reach everything
Status: open
Severity: low (class A noise, 4 times in 2 game years on the new fort)
Found: 2026-10-15 21:10, Run 10 fort Handlelock (region2-site97, y365), dfpilot main 95fe16d + local trade fix
Module: `lua/dfllm/seal.lua` / `care` (CUTOFF), walkable group ids

## Actual
```
#195 A CUTOFF 1 citizens cut off from food: cause not found     (y364 autumn)
#304 A CUTOFF 3 citizens cut off from food: cause not found
#329 A CUTOFF 1 citizens cut off from food: cause not found
#430 A CUTOFF 19 citizens cut off from food: cause not found    (all citizens)
```
Right after #430: `inspect what=reach`: `main group 3302 ... cut: {"bed":0,"drink":0,"food":0}`, citizens `[[3302,19]]`, food 537 / drink 522 items on 3302; Lua: all 19 citizens, the farm and 7 food items in group 3302.
Walkable group ids are renumbered while construction runs (3276 -> 3293 -> 3302 within minutes), so a comparison between a citizen read and a food read taken at different ticks sees "different groups".

## Expected
CUTOFF only after the check holds on two reads of the same tick (or after re-reading the citizens' group), and says which citizen/food pile lies in which group.

Related: BUG-006 (stale reach snapshots)
