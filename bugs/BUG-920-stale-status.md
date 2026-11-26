# BUG-920 Stale status numbers (wood line lagging, drink days on a plateau)
Status: open (not fixed: no proven cause, no code written)
Severity: medium (status text only)
Found: Run 17 i4 Girderroots y484-y491. Status 'wood 0 (350 loose unusable)' while `why items:logs --raw` showed 195-309 free logs; drink days identical over plateaus of 136 d and 99 d while the census tick advanced.
Module: `lua/dfllm/economy.lua` (`M.state`, `T.days`, `T.finish`, `publish`)

## What is proven and what is not
Proven: the status values come from `K.census.i` (wood, woodf, woodt: rebuilt when a sliced census completes, `publish`) and `st.out` (drink_d, food_d: written by `T.days` only when `st.out` is empty or boot-stale, and by `T.finish` of a DAY run), so both change at the pace of the economy run, which on this fort lies hundreds of game days between a census and its tasks (BUG-919, BUG-177). 'wood' counts only free logs near a shop or pile (BUG-910): 0 beside 195-309 free logs is the near rule, not a stale number; autochop's 195-451 is the plugin's own count, a different number.
Not proven: that a plateau is `st.out` not being rewritten (it could equally be a quiet census with an unchanged stock) and the exact lag of the wood line; no census or run duration was measured per publish. Nothing is changed. A fix needs the run and census durations as an event first (a measurement, not a guess).

## Live-Erwartung
None promised, no code. To decide it: kern.log / events of the next run on i4 show how many game days lie between a census start and its finish (BUG-919 `wood_watch` runs at the census end: a WOOD_STUCK `d` or a status change between two census ticks that is far smaller than the gap between two `T.finish` runs would confirm the cadence); until then the wood line and the drink days of the status are read as `age = census tick`, not as a live value.
