# BUG-306 the mood drink nook waits behind the slot holders (a hanging refuge seal)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15b (Earthboat, FR-BUGS Runde 2, y382 aut d21)
Module: `lua/dfllm/runner.lua` (sorted, begin_run slots, Q.mood_proj, Q.join_run, allowed)

## Actual
#5525 MOOD_CRITICAL unit 26555 (Secretive, Bowyers), thirst 53,516. kern.log 154252539 `mood drink nook mdr154252539 queued`, brief `mdr154252539 mood.drink 0% BLOCKED:queued behind c1a1884b90c4405401 +1` (the refuge seal, "suspended by DF" for weeks). The nook was placed at 154256899 (~3.6 days later); the player's `bp.cancel` of the seal is logged at 154257644, after that, so seal first did not pause it (mood_drink was already kind `mood`, never paused, BUG-081): the slot queue held it. Root cause: runner.lua `sorted()` ranked mood_drink with the ordinary projects (rank 2, behind seals and the hospital); `begin_run` gave it a slot only while fewer than `active` (3) projects held one; `second()` let it yield like any project; a project queued mid-run waited for the next `begin_run`. Also `allowed()` froze the nook (class living) in ALERT/RECOVERY.

## Fix
`Q.mood_proj` (mood_drink, or a shop a mood waits for, S.mood_ids): sorts with the hospital (rank 1), takes a slot beside `active` (at most `CFG.mood_slots` 2), never yields unless stalled; `Q.join_run` adds it to the run in hand when it is queued mid-run. The nook is allowed in ALERT and RECOVERY.

## Tests
`tests/lua/test_bug306_309_moods.lua` (BUG-306, 3 tests). Fail on 9ef2ccb.

## Live check
At the next mood nook: kern.log `mood drink nook mdrN queued` and `mdrN (mood_drink) done` within one runner run (a few hundred ticks), never a brief row `queued behind` for an `mdr` project.
