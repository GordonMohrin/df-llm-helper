# BUG-021 CUTOFF "citizens cut off from food: cause not found" fires while everybody can reach everything
Status: fixed (offline, live-untested)
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

## Fix (Claude, 2026-10-16)
- `seal.commit_audit`: a cut the audit saw is confirmed before CUTOFF on groups read again in one go (no yield in between): the citizens and
  one tile per walk group of each vital class (`R.cls[].at`) plus the re-check tiles. Not confirmed: no event, kern.log `seal: CUTOFF not
  confirmed: ...`, `inspect reach` `runs.cut_unconfirmed`, and the stored cut counts are the re-read ones (no repeat on the next audit).
- CUTOFF names who stands where (e.g. `3 citizens cut off from food: wall at 7,11,9; citizen 1 at 9,9,9 on group 412, food at 9,13,9 on group
  415`), `d.unit`, `d.upos`, `d.grp`, `d.at`, `d.agrp`.
- The entrance check starts over when the citizens' tiles changed group while it ran (`same_groups`, at most three passes), the same race
  in another job (it made a sealed opening record no perimeter pieces in a test).
- Tests: `tests/lua/test_seal_refuge.lua` (a renumbering in the middle of an audit: no CUTOFF; a real cut names the citizen and the stock
  with their groups), `tests/test_seal_files.py` (the CUTOFF fields), the first failing on 6e34f8a.
