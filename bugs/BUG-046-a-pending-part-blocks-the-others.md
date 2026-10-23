# BUG-046 One part of a project that is never built keeps a refused part of the same project from being placed again: the kitchen behind the forge
Status: fixed in 73b429d (offline, live-untested): a lost or refused part is placed again whatever the other parts wait
for; PROJECT_BLOCKED names the parts that wait; the workshops template puts the food shops first
Severity: high (kitchens 0 and food 10 days in Run 12; PrepareMeal orders hang)
Found: 2026-10-18, Run 12 fort Trussroads (Reclaim), from the game session's note 32 (triage A1)
Module: `lua/dfllm/runner.lua:670-687` (measure_build), `:3278` (blocked_event), `dfpilot/bp/rooms.py:207` (workshops)

## Actual (live, game session, note 32)
"Run 12: kitchen missing (kitchens 0), food 10 d. The workshops project c1a14cea287d746a01 stands at 62 % 'stalled'
because the forge (MetalsmithsForge 22236 at 72,61,129, job ConstructBuilding items 2, not working) is never built; the
kitchen (wk) behind it in the chunk order was never placed because of that. PrepareMeal orders (4+10) hang. I placed a
kitchen by hand with quickfort at 93,98,127."

## Cause (proved from the code at f17e2b3)
1. **The runner does not place chunks one after the other** (`work` applies every chunk of a stage before it measures), so
   "behind it in the chunk order" is not the mechanism. The mechanism is the measure: `measure_build` counts the stage's
   buildings (`R.b`, `R.c`) and the parts quickfort refused (`R.uns`) or that vanished (`#R.b - #keep`), then returns
   `'done'` as soon as one building is pending (runner.lua:687), **before it looks at the lost parts**. The one re-apply of a
   stage (`lost > 0`, `R.ra`) ran only once every other building was built. A forge that is never built means a part
   quickfort refused at the first placement (a unit or an item on its tile for a moment) is never placed again, and
   the stage never completes. The project's row says `stalled`, nothing names which part waits (blocked_event had no part
   list).
2. **The order of the template.** `workshops` put the moodable shops first and the food shops (`add`: Still, Kitchen,
   Butchers, Fishery) last (rooms.py:207); quickfort plans buildings in grid order, so buildingplan attaches its materials
   to the forge before the kitchen, and a fort short of building material feeds the forge first.

## Fix
- `measure_build` places a lost or refused part again whatever the other parts do: the first re-apply at once (as
  before), more while parts wait up to `reapply_max` (6) times, `reapply_gap` (a game day) apart (a unit or an item in
  the way goes in hours; the old single immediate attempt was spent before it did). After the last pending part is built
  the old rule holds (one more re-apply only for a seal whose pieces economy can make; the `lost_pct` block).
- PROJECT_BLOCKED for `stalled` names the parts that wait (`d.parts`, msg `blocked: stalled at build; waits:
  MetalsmithsForge 72,61,129: job 22236 suspended by buildingplan: waits for building material x1`): the cells of the
  stage not built yet, each through `economy.build_state` (BUG-044), at most 3.
- The `workshops` template lists the food shops first, so the kitchen is the first building planned in the room.
- The stall of one part does not freeze the rest: the stage completes only when every part is built, as before, but
  nothing else of the project (a later stage) was waiting on a single part's placement any more than on the stage.

## Not decided offline
- **Whether the live kitchen was refused/lost at its placement or was planned and starved of building material behind
  the forge.** The new `parts` line says it (`nothing stands at x,y,z` = never placed or removed; `suspended by
  buildingplan: waits for building material x1` = planned, no material); read-only: `dfllm events --type PROJECT_BLOCKED`
  of the project, `dfllm cmd inspect workload` (`construction.missing`: building material x N).
- **buildingplan's allotment order.** That the first planned building gets the scarce material first is buildingplan's
  documented queue; the live order was not read. Decides it: two planned shops, one boulder at a time, which one gets it.

## Tests
`tests/lua/test_runner_seal_door.lua` (a refused part placed again while the forge pends; `parts` in PROJECT_BLOCKED),
`tests/test_bug044_files.py` (the contract field, the template order). Each fails on f17e2b3.

## Related
BUG-022 (build_lost and its retry), BUG-037 (slots), BUG-044
