# BUG-004 planned buildings wait for forbidden items for ever, JOBS_SUSPENDED repeats the same line
Status: open
Severity: high (nine coffins, a bed and the trade depot could not be built for 30+ real minutes while 20+ citizens had no work)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/economy.lua:2999` (FR-16 job release, `JOBS_SUSPENDED`); items side: nothing unforbids construction materials

## Expected
Planned buildings whose material items are forbidden (or unreachable) are noticed and fixed: the kernel unforbids the
item (a player would) or reports the item ids and the reason once.

## Actual
```
JOBS_SUSPENDED construction jobs: 11 suspended, 2 resumed, 0 kept, 9 planned (buildingplan: waiting for materials x9; suspended x2)
```
Same line on every day for 30+ real minutes (#8640, #8646, #8655 ...). Lua showed 9 Coffin construction jobs `flags: suspend`, `items 0`,
and 8 loose coffin items with `on_ground, forbid`. After unforbidding the 8 coffin items by hand, the buildings were built
within about 2 minutes (coffins built 243 -> 251) and the dead went in.

## Cause (suspected)
FR-16 resumes suspended jobs but treats "waiting for materials" as a state to report; FR-23/FR-50 unforbid seeds and
food/drink containers only. Loose forbidden items of a building's material class are not touched.

## Fix proposal
In the same daily pass: for each "buildingplan: waiting for materials" building, find forbidden loose items of the required
class on reachable tiles of the fort (not the mood reserve's holds, which care marks) and unforbid them; if none exist, say
which class is missing (`inspect what=workload`).

Related: FR-16, FR-61, BUG-005
