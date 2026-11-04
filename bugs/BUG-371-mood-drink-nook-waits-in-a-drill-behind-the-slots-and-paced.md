# BUG-371 the drink nook of a moody dwarf waits (drill freeze, mood slots, paced runner) and is reported 'queued' after it stands
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16d (i4 Plankscale, y376/y377: citizens 26531 and 26274 died of thirst 75,002 in Possessed/Secretive moods), main 2fcd6e0
Module: `lua/dfllm/runner.lua` (allowed, the slot loop, join_run, rows, step), `lua/dfllm/care.lua` (mood_relief)

## Actual
`runs/run-16d/FR-BUGS.md`: the MOOD_RISK line said 'drink nook queued (mdr...)', the project stood 'queued behind y375s1b0' at 0 %
for 8+ days; the dwarf died of thirst. The i4 log (`dfllm-runtime/r16d-woodmill-site97/kern.log`) shows what really happened:
- mdr151581506 (unit 26531) was queued at tick 151581506; between 151584979 and 151586179 the mode was DRILL (bridge drill) and
  `allowed()` froze every project but the plug in it; the project ran at 151586784, 5,278 ticks after it was queued. In the same
  seconds the kernel logged `runner paced: over its share of 4 ms/s ... runs and slices wait`.
- The nook is queued at thirst 40,000 (`mood_act`); all four nooks of the run (26490, 26531, 26399, 26274) ran within 5,300
  ticks of being queued. 26531 and 26274 still died: their cloth/gems were missing (BUG-372), a nook cannot save a dwarf whose
  mood job never starts. The player's '8+ days' is the stale row/text: MOOD_CRITICAL kept 'drink nook queued at ...' after the
  nook stood (care.lua `p.nook[sid].txt`, never updated), and the project row read 'queued behind <first slot holder>' for
  every project not yet in `S.active`, a mood project included.
- A third mood project (mood shops project + mood shops project + nook) was held by `mood_slots` = 2 (BUG-306 gave the
  nook a slot beside `active`, but capped at two for all mood projects together), and seals sort before it and take `active`.

## Root causes
- runner.lua `allowed`: only PEACE/ALERT/RECOVERY (and SIEGE for life support) let a mood_drink run; DRILL fell through to false.
- runner.lua slot loop / `Q.join_run`: `nm < mood_slots` also applied to the one-tile nook.
- runner.lua `rows`: any allowed, unscheduled project is 'queued behind <holder>', also a mood project that starts in the next run.
- runner.lua `step`: nothing asked kern for the boost while a nook was pending (a paced runner waits for its share).
- care.lua `mood_relief`: the nook was queued in PEACE/RECOVERY only (ALERT, DRILL: nothing); `done.txt` said 'queued' forever.

## Fix
- `allowed`: mood_drink also in DRILL. care `mood_relief`: queues in ALERT and DRILL as well (SIEGE/BREACH read no tile, FR-82 stays).
- The nook is exempt from `mood_slots` (scheduler and `join_run`); it still goes first (sorted with the hospital).
- `rows`: a waiting mood project reads 'mood: starts next run', never 'queued behind'.
- `Q.mood_boost` (step): K.boost while a mood_drink is pending, K.unboost when none is.
- care: after quickfort placed the nook the text reads 'drink nook stands at x,y,z (id)'.
Not changed: the trigger (`mood_act` 40,000 thirst), gate.lua and bridge logic.

## Tests
`tests/lua/test_bug371_373_moods.lua` (DRILL, mood_slots, row text, boost) and `tests/lua/test_care_nook.lua` (ALERT/DRILL queue,
'stands at'); all fail on 2fcd6e0.
