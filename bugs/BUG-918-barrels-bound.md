# BUG-918 Barrels bound as stockpile containers: the release never acted, and never said why (PILE_BARREL_RELEASE)
Status: fixed (offline, live-untested)
Severity: high (i4 brews little; drink 57 -> 343 d only by caravans or luck)
Found: Run 17 i4 Girderroots y491, kernels 13700af3 / 8c553a52, DF E:/DF-test4. `why brew`: 'DF cancelled brew drink ... Needs empty food storage item'. `why items:barrels --raw`: '115 of 121 empties are registered in the storage.container_item_id of a stockpile', cont_free 0 (kern.log:235 '1 usable of 118 empty barrels or pots (88 held by stockpiles as their containers)'); BREW_CANCEL_SNAPSHOT #43119..#43121 loc `dfllm-stock=87;none=3;dfllm-drink=1;dfllm-start=1`, 91 free empties, cancels 34-37 / 7 d. A MakeBarrel x10 raised the empties 114 -> 116 only (piles bind new barrels at once). No PILE_BARREL_RELEASE event on any of the four forts.
Module: `lua/dfllm/economy.lua` (`M.pile_release`, `M.release_none`, `M.release_watch`, `M.release_emit`, `M.watch`, `M.brew_watch`), `dfpilot/schema.py`

## Proven / not proven
Proven (read from the logs and the code):
1. The container gate (`cx_gate`) was OFF 196.44M-196.51M and 197.0M-198.1M (kern.1.log:776, 859, 1785) and went ON at 198106769 (kern.log:1050 'container cure ON ... 12x'). The diagnosis' 'window stays at 20' is NOT a counter fault: `cxn` of BREW_CANCEL_SNAPSHOT is the size of the cancel-moment ring (brewsnap `moment_stats`), the window count itself is 12-53 (`cancels`).
2. The release (`pile_release`) ran only inside the daily run (`brew_watch`, `r.day`) with `r.now` = the tick the run's CENSUS started at. On this fort a run lies up to ~350 game days between its census and its tasks (BUG-919), so the release was tried once per run, on stale days.
3. A release call that lowered nothing wrote nothing (`res.kept` was logged only for 'accepts drink', `res.failed` never): 'no pile qualified' and 'the limit write failed' looked like 'never ran'. Only a lowering produced PILE_BARREL_RELEASE.

NOT proven: that lowering a pile's `max_barrels` makes DF drop the registered empties from `storage.container_item_id` (the live run measures it, d1 / d7); why the one earlier release call (kern.1.log:1671, tick 196930579) found only pile 17706 (the other reasons were not logged).

## Fix
1. `M.release_watch` (new, called from `M.watch`, the kernel's guaranteed look every 600 ticks): the existing `M.pile_release` once per game day at the REAL tick with the kernel's own state and census. The SAME mechanism (act `pile_barrels release`, BUG-844 gate on DF's reason, BUG-867 hysteresis, `relstop`, 14-day bound, d1 / d7 measurement); no second one. Once it ran, `brew_watch` no longer calls `pile_release` with the run's stale clock (`st.relwatch`); without the look the run path is unchanged.
2. `M.release_none`: a call with the gate open and registered empties in the census that lowered NO pile (and no lowering in progress) emits PILE_BARREL_RELEASE `phase none` once per game week: registered empties (`reg0`), free empties (`free0`), piles looked at (`kept`), failed limit writes (`failed`, also a kern.log warn with the first ids), cancels in the window (`cx0`) and the reasons per pile in the text ('N limit already low, N not a kernel food pile, N accepts drink, ...').
3. `M.release_emit`: `free0` / `free1` / `free7` = the census' free empty containers at the lowering / after 1 d / after 7 d, beside the registered ones and the cancels. The d7 verdict stays (registration kept: `relstop`, no pile lowered again, the old limit goes back at once = it says so and stops repeating).
Never dumped, destroyed or written: items, `container_item_id`; player piles are not touched (kernel `dfllm-*` food piles that accept no drink only, as before).

## Tests
`tests/lua/test_bug918_pile_release.lua` (free empties in the d1 event, `phase none` once per week with the reasons and no write, no `none` while a lowering is measured, `release_watch` once per game day), `tests/lua/test_bug887_round6_registry.lua` unchanged (9 pass).

## Live-Erwartung
i4 (container reason ON since 198106769): within one game day of the look a kern.log line 'pile barrel release (lowered): pile N barrel limit 9 -> 0 ... free empties F' or, when nothing qualifies, PILE_BARREL_RELEASE `phase none` with the numbers and reasons. After 1 and 7 game days `d1` / `d7`: `reg1` / `reg7` below `reg0` and `free7` above `free0` prove the lowering (cancels `cx7` falling); `reg7 >= reg0` gives 'DF kept the registration', the limits go back and nothing is lowered again (refuted: DF keeps its container list). `phase none` with `failed` > 0: the write field is the next suspect (pilelib). Not promised: that brews run.
