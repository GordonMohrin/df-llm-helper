# BUG-887 Empty barrels counted as free that no brew can take
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 / i2 (25.11.): census 'empty' barrels 27-42 beside DF's 'Needs empty food storage item' 100-250x a week for a year (i2 y500-y522: 29-42 empties that never change); the `why items:barrels --raw` samples show trader barrels (refs UNIT_TRADEBRINGER without the trader flag) and barrels lying in the mood pile `dfllm-mood` (max_barrels=1).
Module: `lua/dfllm/economy.lua` (`classify` BARREL branch, `M.barrel_trader_ref`, `M.mood_pile_at`, `M.cont_words`, `M.cont_text`)

## Root cause
CONFIRMED on i2 (diagnosis C2, partly): the census already skipped barrels with the item flags trader / in_building / forbid / dump (the skip mask), a barrel held by a job and a barrel on a tile with no walk group; it did NOT skip a barrel whose owner is a merchant (general ref UNIT_TRADEBRINGER) nor a barrel in the one-barrel mood pile. Both were `barrels_empty` and `cont_free` although no Still job can take them. The wording everywhere said 'N empty barrels' (stall line, ladder, DECISION text), so a fort with 42 'empty' and 0 usable read as 'has barrels'. NOT found: why DF skips the remaining ~30 'free' empties of i2 (unknown 1 of the diagnosis; the stale `container` flag idea stays a hypothesis).

## Fix
Census: each empty barrel is counted ONCE under the first reason that holds: `barrels_trader` (ref UNIT_TRADEBRINGER), `barrels_mood` (inside a `dfllm-mood` pile rectangle), `barrels_busy` (a job holds it), `barrels_far` (no walk group), else `cont_free` (usable). `barrels_forb` counts forbidden barrels (never in `barrels`). `M.cont_words` / `M.cont_text` give '7 usable of 42 empty barrels or pots (20 a trader's, 10 in a mood pile, 5 held by a job, 3 forbidden (not counted))'; used by the brew stall line, the 'nobarrel' verdict (`not usable: ...`), the ladder ('no usable empty barrel or pot: ...'), the DECISION text and state `stock.contw` (brief: `containers 7 usable of 42 empty (...)`). The reserve, the ladder and the stall verdict already read `cont_free`, so they now see the smaller number.

## Tests
`tests/lua/test_bug887_891_fass.lua` (i2 state: 418 barrels, 376 full, 42 empty = 20 trader + 10 mood + 5 job + 7 usable, 3 forbidden beside; words and text), `tests/test_bug887_891_fass.py` (contract `stock.contw`, brief text).

## Live-Erwartung
i1/i2 status line shows `containers N usable of M empty (reasons)`; the stall and ladder lines say the same; the number that triggers the container cures is the usable one. NOT promised: that every barrel counted usable is taken by DF (the ~30 dead empties of i2 may remain until the cause is found; the stall verdict still uses DF's own cancel words, not the count).
