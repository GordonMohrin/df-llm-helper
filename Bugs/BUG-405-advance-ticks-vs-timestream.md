# BUG-405: `claude/advance <ticks>` counts frames, not calendar ticks -> overshoots when timestream is on (hypothesis, needs a run with running time)

- **Status:** fixed, live check pending (see TESTPLAN-live) [code reviewed; needs timestream run]
- **Severity:** S2 (time-lapse guard is a core safety feature of df-llm-helper)
- **Area:** `lua/claude/timer.lua:15-25` (`start`), `lua/claude/advance.lua:55-64`; evidence for the semantic is the author's own comment in `lua/claude/tempo.lua:13-15`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), live `config.lua` has `TIMESTREAM = true` (`TIMESTREAM_FPS = 200`), repo default is `false`

## Command / steps
(not run - forbidden by the test rules)
```
dfhack-run.exe claude/advance clock         # note year_tick
dfhack-run.exe claude/advance 1200
# wait until paused again
dfhack-run.exe claude/advance clock         # year_tick difference?
```

## Expected
The game pauses after 1200 **game ticks** (`target` in the `advance` answer = `cur_year_tick + 1200`).

## Actual (predicted)
`timer.start(ticks)` computes `target` as `cur_year_tick + ticks` and arms `dfhack.timeout(ticks, 'ticks', ...)`. `tempo.lua:13-15` documents the measurement "repeat-util/dfhack.timeout 'ticks' counts REAL simulation frames (world.frame_counter), NOT calendar ticks. With timestream 2..9 calendar ticks pass per frame". With timestream enabled the game would therefore run `ticks x 2..9` calendar ticks (and the 1-month cap `util.TICKS_PER_MONTH` becomes up to 9 months), while the `target` shown to the caller is wrong. The author already switched the safety jobs to `tempo.schedule()` (calendar based); `advance`/`timer` were not converted.

## Evidence
none (cannot be produced with the game paused). Live `claude/tempo status` right now: `"timestream": false, "grund_aus": "zivilwarnung", "faktor_x100": 100` (`Bugs/evidence/BUG-416/tempo_status.out.txt`) - i.e. timestream is currently off because the civil alert is on, so a test would have to be done with the alert off.

## Analysis (reporter's hypothesis)
See above; `timer.active()` also relies on the same timeout id.

## Suggested fix (optional)
Use `claude/tempo`'s `schedule(key, calendar_ticks, fn)` (poll every few frames, compare `cur_year*403200 + cur_year_tick`) in `timer.start`, or suspend timestream (`reqscript('claude/tempo').suspend('advance')`) while a timer runs.

## Info needed
- Player: with the civil alert off and timestream on (`claude/tempo status` -> `timestream: true`), run `claude/advance clock`, `claude/advance 600`, wait for the pause, `claude/advance clock` and send both `date.year_tick` values. Expected difference 600; a difference of ~1200-5400 confirms the bug. (Needs running game time; I was not allowed to unpause.)

## Fix
`timer.start` re-arms itself with a tenth of the remaining CALENDAR ticks and pauses when the calendar target is reached (overshoot at most one frame); mock simulation with 1/3/9 calendar ticks per frame. Info needed (player, live): the check from this report (`advance clock`, `advance 600`, `advance clock`) with timestream on; expected difference 600..609.
