# BUG-919 WOOD_UNMARK / WOOD_STUCK ran on the census' start tick: first removal 377 days late, '552 game days' for 199, new logs 0 after 18 felled trees
Status: fixed (offline, live-untested)
Severity: high (the clock of every wood measurement; i4 wood waited a game year)
Found: Run 17 i4 Girderroots y484-y491, kernels 13700af3 then 8c553a52. WOOD_STUCK #39515 tick 195148800 (d 1497) and #39666 tick 195228568 (d 1649): 66 real game days, +152 in `d`. The first WOOD_UNMARK `did` #40329 tick 195681269 came 377 game days after the reload at 195217539 (economy.wood.unmark_days is 7). Its `result` #40615 tick 195920508 says 'days 552, trees felled 18, new logs 0' for 239,239 ticks = 199 game days. The `d` of the earlier WOOD_STUCK events wobbles against their ticks (911 -> 1175 over 133 days).
Module: `lua/dfllm/economy.lua` (`M.wood_watch`, `M.wood_stuck`, `M.wood_unmark`, `M.wood_unmark_follow`, `T.chop`, `M.step`, `publish`)

## Proven (code, logs) and INFERRED (marked)
Wording rule (lead D5): everything not read from a live line is marked INFERRED here. The '552 game days' mechanism below is INFERRED, not measured: no log shows when the census of that run began.
`T.chop` called the three functions with `r.now`, and `r.now` is `cs.start`, the tick the census of the run began at (`M.step`: `st.run = new_run(K, c, cs.start)`). A run is sliced; BUG-177 already noted 'the first daily run took ~40 game days'; on i4 the run between its census and its chop task (emitted at 195681269) is INFERRED to have started near 195.26M (just after the boot at 195217539): that start is not read from any log, it is what the numbers need. So `rec.t0`, `rec.t`, `pend.t` and every `days` were stamped with a census start. The 552 is (INFERRED, not measured) consistent with a `pend.t` near 195.26M and a later census start (about 195.26M + 552 days = 195.92M) against 199 real days: an inference, not a measured value. That the first removal came late because T.chop was reached only at the end of a very long run is likewise inferred (no WOOD_STUCK event in between = T.chop did not run); the offline test below reproduces the effect, the live cause is not read from a log. `new logs 0`: `wood_new` counts logs with an id above `st.wood_mark`, the highest id of the previous reading, kept only in memory: the reload at 195909559 zeroed it, so the first reading after it counted no new log.
Not proven: which silent early return of `wood_unmark` (mode DRILL at #39666, unreadable groups, nothing marked) applied in the unseen runs.

## Fix
0. `M.wood_look` (called from `M.watch`, once per game day, real tick, on the last census): `M.wood_watch` no longer depends on a run reaching T.chop or on a census ending, so the removal follows `stuck_days` after the stuck state is readable.
1. `M.wood_watch(K, c, inv)`: follow + stuck at the REAL tick (`K.now().tick`); called from `T.chop` (instead of `r.now`) and from `M.step` right after `publish` (the end of the census), so the check no longer waits for the long run to reach its chop task.
2. `M.wood_unmark`: a look that finds nothing to take down (no marked tree, groups unreadable, all reachable) sets only `rec.try` (retry after one game day); `rec.t` (the `unmark_days` window) is set by a removal only.
3. `M.wood_unmark_follow`: `now < pend.t` (an older save was loaded) re-dates the pending removal instead of measuring at once; days are real.
4. The highest log id of a complete reading is persisted (`m.economy` `wood_mark`) and restored when the census starts, so a reload does not count the first reading's new logs as none.
Not changed: WOOD_STUCK `d` keeps its meaning (days since `rec.t0`), now on the real clock; DRILL stays outside PEACE / RECOVERY.

## Tests
`tests/lua/test_bug919_wood_clock.lua` (real days in the result, re-dating after an older save, a miss does not burn the window, persisted `wood_mark`; and the slow-census shape: the economy entry off, `M.step` every 25 game days with 4 items a slice (census plus run of ~100+ game days), `M.watch` every day, stuck state readable from day 151: this commit removes the designations on day 154 (3 days later) and the result says 2 game days for 2 real; the SAME test against main's economy.lua (8c553a52, 1500 days) removes them on day 676, 525 game days after the stuck state was readable); `tests/lua/test_bug917_wood_unmark.lua` unchanged (7 pass).

## Live-Erwartung
i4 / i1: the first WOOD_UNMARK `did` within 3 game days of WOOD_STUCK holding plus one census (not hundreds of days); `result` `days` = (tick difference of the two events) / 1200, about 2-3; `new` > 0 after trees fell even across a reload; WOOD_STUCK `d` monotonic against the ticks.
