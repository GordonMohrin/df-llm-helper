# BUG-402 dehydration deaths with drink 0 are not a top status line
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16a (i1 Mansionlauded, 13 of 16 dead of thirst), main 503bb8b
Module: `dfpilot/brief.py`

## Actual
While the fort died of thirst, `status` showed `stock drink 0d!`, a `drink: nobody thirsty: they drink water` cause line (BUG-259 text),
and the dead only as `deaths (season) dehydrated 13` in a rank-4 line that status drops first. Nobody reading the status saw why.

## Root cause
`brief.supply_items` puts the deaths in the `care` bundle (rank 4); only strange moods (BUG-285) had a line under the clock.

## Fix
`brief.thirst_items`: drink at 3 days or less and (DEATH events with cause dehydrated within a month, else the season's `care.died`) or
patients over thirst 50,000 -> a rank-1 line right under the clock line of `status` and `brief`: `DYING OF THIRST: drink 0d, 13 dead of
dehydration this month: <reason> (dfllm cmd inspect what=reach / water_sources; events --cls A)`. Reason: the kernel's drink cause
(`stock.dwhy`: `no reachable water`, `N stranded without drink`), else `no accepted water and no brewed drink`, else the accepted water
is out of their reach.

## Open
Needs `stock.drink_d` in the state (always there once economy ran). Deaths older than a month fall back to the season count only when
no DEATH event is in the window.

## Tests
tests/test_bug400_402_water.py (2 for 402).

## Live check
`status` of a fort with citizens dying of dehydration and drink 0: second line `DYING OF THIRST ...`, above the MOOD lines.
