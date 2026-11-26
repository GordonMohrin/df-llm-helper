# BUG-919 WOOD_UNMARK / WOOD_STUCK ran on the census' start tick: first removal 377 days late, '552 game days' for 199, new logs 0 after 18 felled trees
Status: fixed (offline, live-untested)
Severity: high (the clock of every wood measurement; i4 wood waited a game year)
Found: Run 17 i4 Girderroots y484-y491, kernels 13700af3 then 8c553a52. WOOD_STUCK #39515 tick 195148800 (d 1497) and #39666 tick 195228568 (d 1649): 66 real game days, +152 in `d`. The first WOOD_UNMARK `did` #40329 tick 195681269 came 377 game days after the reload at 195217539 (economy.wood.unmark_days is 7). Its `result` #40615 tick 195920508 says 'days 552, trees felled 18, new logs 0' for 239,239 ticks = 199 game days. The `d` of the earlier WOOD_STUCK events wobbles against their ticks (911 -> 1175 over 133 days).
Module: `lua/dfllm/economy.lua` (`M.wood_watch`, `M.wood_stuck`, `M.wood_unmark`, `M.wood_unmark_follow`, `T.chop`, `M.step`, `publish`)

## Proven
`T.chop` called the three functions with `r.now`, and `r.now` is `cs.start`, the tick the census of the run began at (`M.step`: `st.run = new_run(K, c, cs.start)`). A run is sliced; BUG-177 already noted 'the first daily run took ~40 game days'; on i4 the run between its census (about 195.26M, just after the boot at 195217539) and its chop task (emitted at 195681269) took ~420,000 ticks. So `rec.t0`, `rec.t`, `pend.t` and every `days` were stamped with a census start. The result's `days` = (start of the NEXT census, right after the reload at 195909559) - (start of the did run, about 195.26M) = about 650,000 ticks = 552 days; real elapsed 199. The first removal 'came late' because T.chop of that run was reached 377 days after the reload (no WOOD_STUCK event in between because T.chop did not run), not because of the 7-day window. `new logs 0`: `wood_new` counts logs with an id above `st.wood_mark`, the highest id of the previous reading, kept only in memory: the reload at 195909559 zeroed it, so the first reading after it counted no new log.
Not proven: which silent early return of `wood_unmark` (mode DRILL at #39666, unreadable groups, nothing marked) applied in the unseen runs.

## Fix
1. `M.wood_watch(K, c, inv)`: follow + stuck at the REAL tick (`K.now().tick`); called from `T.chop` (instead of `r.now`) and from `M.step` right after `publish` (the end of the census), so the check no longer waits for the long run to reach its chop task.
2. `M.wood_unmark`: a look that finds nothing to take down (no marked tree, groups unreadable, all reachable) sets only `rec.try` (retry after one game day); `rec.t` (the `unmark_days` window) is set by a removal only.
3. `M.wood_unmark_follow`: `now < pend.t` (an older save was loaded) re-dates the pending removal instead of measuring at once; days are real.
4. The highest log id of a complete reading is persisted (`m.economy` `wood_mark`) and restored when the census starts, so a reload does not count the first reading's new logs as none.
Not changed: WOOD_STUCK `d` keeps its meaning (days since `rec.t0`), now on the real clock; DRILL stays outside PEACE / RECOVERY.

## Tests
`tests/lua/test_bug919_wood_clock.lua` (real days in the result, re-dating after an older save, a miss does not burn the window, persisted `wood_mark`); `tests/lua/test_bug917_wood_unmark.lua` unchanged (7 pass).

## Live-Erwartung
i4 / i1: the first WOOD_UNMARK `did` within 3 game days of WOOD_STUCK holding plus one census (not hundreds of days); `result` `days` = (tick difference of the two events) / 1200, about 2-3; `new` > 0 after trees fell even across a reload; WOOD_STUCK `d` monotonic against the ticks.
