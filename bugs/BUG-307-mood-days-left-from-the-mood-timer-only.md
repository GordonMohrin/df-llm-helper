# BUG-307 MOOD line days left from DF's mood timer only, not from thirst/hunger
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15b (Earthboat, FR-BUGS Runde 2, y382)
Module: `lua/dfllm/mood.lua` (MD.left, MD.left_text)

## Actual
status/brief `MOOD ... Secretive needs its materials: nothing missing, 41 d left` while the dwarf stood at thirst 53,516: a moody dwarf neither drinks nor eats, and death at 75,000 (care's `dies at 75000`) was ~18 days away. Root cause: mood.lua MD.left returned DF's `unit.job.mood_timeout` (or the claim estimate) and never read `counters2.thirst_timer`/`hunger_timer`; MOOD_CRITICAL reason `timer` and the 20/10/5/2-day steps used the same number.

## Fix
MD.left = the nearest of the mood clock and the two body clocks (`MD.DIE` 75,000 minus thirst or hunger, one a tick); lsrc `thirst`/`hunger` then, line `17 d left (thirst 53516)`. The `timer` reason and the steps follow it. Schema comment, CONTRACTS MOOD_CRITICAL row (lsrc), RULES row.

## Tests
`tests/lua/test_bug306_309_moods.lua` (BUG-307); `tests/lua/test_mood_emergency.lua` updated (no claim yet: the body clock is known). Fail on 9ef2ccb.

## Live check
At the next mood with thirst over ~40,000: status `MOOD ... N d left (thirst T)` with N = (75000 - T) / 1200; MOOD_CRITICAL `d.lsrc` thirst. Uncertain: whether hunger kills at 75,000 too (a stranded woodcutter outside a mood lived at hunger 120,415); thirst is the nearer clock in every Run 15 mood death.
