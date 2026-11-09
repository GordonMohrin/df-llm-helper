# BUG-610 The hard-stone denial runs out after 14 days and the rock orders cancel again
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-09, Run 16a i1 Basementflew y426-y429 (Mason / Carpenter orders `Needs non-economic hard stone` again and again, the boulders out of DF's reach)
Module: `lua/dfllm/economy.lua` (`M.hard_cancel`, `M.hard_denied`, `M.hard_report`, `M.HARD.sticky`)

## Actual
The hard-stone denial runs out after 14 days and the rock orders cancel again.

## Root cause
BUG-545 held the stone at 0 for 14 days after the last cancel; then the rock orders were queued, DF cancelled them three times and the hold started over, for as long as the boulders stayed out of reach, with the question asked every 28 days.

## Fix
`hard_cancel` counts the episodes (`st.hard.eps`; a first cancel after the hold ran out and three more make the next one); from the second (`M.HARD.sticky` 2) `hard_denied` has no time limit: stone counts 0 until more than `M.HARD.new` boulders beyond the count at that cancel; the question is asked once with the words `again ... no rock order is queued until more than 5 new boulders come` (and the census' out-of-reach count). New boulders start a fresh first episode.

## Tests
`tests/lua/test_bug607_612_econ.lua` (first episode ends, second is held, new boulders lift it, a fresh denial is a first one)

## Live check
kern.log shows the `again` warning once; no `Needs non-economic hard stone` cancels after it until boulders come.
