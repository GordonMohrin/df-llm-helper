# BUG-920 Stale status numbers (wood line lagging, drink days on a plateau)
Status: open (not fixed: no proven cause, no code written)
Severity: medium (status text only)
Found: Run 17 i4 Girderroots y484-y491. Status 'wood 0 (350 loose unusable)' while `why items:logs --raw` showed 195-309 free logs; drink days identical over plateaus of 136 d and 99 d while the census tick advanced.
Module: `lua/dfllm/economy.lua` (`M.state`, `T.days`, `T.finish`, `publish`)

## What is proven and what is not
Proven: the status values come from `K.census.i` (wood, woodf, woodt: rebuilt when a sliced census completes, `publish`) and `st.out` (drink_d, food_d: written by `T.days` only when `st.out` is empty or boot-stale, and by `T.finish` of a DAY run), so both change at the pace of the economy run, which on this fort lies hundreds of game days between a census and its tasks (BUG-919, BUG-177). 'wood' counts only free logs near a shop or pile (BUG-910): 0 beside 195-309 free logs is the near rule, not a stale number; autochop's 195-451 is the plugin's own count, a different number.
Not proven: that a plateau is `st.out` not being rewritten (it could equally be a quiet census with an unchanged stock) and the exact lag of the wood line; no census or run duration was measured per publish. Nothing is changed. A fix needs the run and census durations as an event first (a measurement, not a guess).

## Live-Erwartung (what to compare; no code, nothing promised)
1. Wood line: take `status` (its `wood N usable (F far, M loose unusable)`) at tick T and, in the same minute, `why items:logs --raw` (free logs near / far) and the newest kern.log line 'economy: wood stuck: ... (near N, far F ...)' (written at the real tick since BUG-919 from `K.census.i`). Equal numbers in the status and in that line, both different from `why items:logs --raw`, mean the status shows the last COMPLETE census (age = T minus the census end): not a text bug. Different numbers in the status and in the kern.log line for the same census would be a real defect.
2. Drink days: two `status` reads 30+ game days apart with identical `drink` days while the DRINK stock (inspect what=items key=drink) changed = `st.out` not rewritten by a finished run (the cadence cause). Changed stock and changed days = no defect.
3. The measurement that would settle it (NOT written; to add if 1 or 2 shows a lag): one event per game week with the census start tick, the census end tick, the tick the last economy run finished (`T.finish`) and the age of the published `drink_d`. Until then the wood line and the drink days of the status are read as 'as of the last complete census / run', not as live values.
