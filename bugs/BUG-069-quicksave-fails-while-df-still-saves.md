# BUG-069 `dfllm save` reports QUICKSAVE_FAILED after 122 s while a big world needs 54-110 s (and more) to save
Status: fixed in c80a2fe (offline, live-untested): the wait follows the real duration (files below `save/current`), a save
still being written is `running` (exit 4), not a failure, a save that lands after the wait is found and the record
corrected (`late`), no second quicksave while DF writes or a verified autosave just saved the fort, every outcome has its
own kind and message; limits in config `save`
Severity: medium (a false alarm wakes the LLM and the player: "the game is not saved"; a retry two minutes later starts a
second save on top of a running one in a world where one save freezes the game for 1-2 minutes)
Found: 2026-10-22, Run 13 fort Wheelsblows (region2-site84), y506 autumn d11, from the game session (note 39)
Module: `dfpilot/save.py` (`quicksave`, `refusal`, `run`), `dfpilot/supervise.py` (`writing`), `dfpilot/wake.py`
(`_check_quicksave`), `dfpilot/brief.py` (`line_save`), `tools/run_watch.py` (`save_verified`)

## Actual
```
dfllm save  ->  QUICKSAVE_FAILED: no fortress save folder newer than the call after 122 s (dfhack-run printed nothing);
                the newest save is 'autosave 2' from 12 min ago
```
In that world (region2) quicksaves took 54-110 s; the game session could not tell a save that was still running from
one DF never started, and a retry after 120 s (`RETRY_S`) would have started a second quicksave.

## Expected
The wait ends when the save is done or DF stopped writing, not at a fixed second; "still running" and "failed" are
different results with different messages; no second quicksave starts while DF writes or an autosave has just saved the
fort; a save that lands late corrects the record instead of leaving a false failure.

## Cause
1. **Proven from the code (base f17e2b3): a fixed deadline, no sign of life.** `quicksave` waited `deadline = clk() +
   timeout` (save.py:75, default `WAIT_S = 120`, save.py:25) and left the loop at `if now >= deadline: break`
   (save.py:86) whatever DF did. A big world that needs 110 s plus the freeze before dfhack-run's command is processed
   (the command runs on a frame DF serves after the autosave freeze, 24-27 s, BUG-070) passes 120 s.
2. **Proven: the only "DF is writing" sign was the last second.** `supervise.busy` (supervise.py:437) is true when
   `save/current/world.sav` exists, and DF writes `world.sav` last (its docstring), so a 100 s write showed nothing until
   its end; the failure text `DF was still writing save/current` therefore appeared only when the deadline fell into that
   last second.
3. **Proven: failure and "slow" were one record.** `ok:0` with `fails` 1 (save.py:105) was both; follow woke
   QUICKSAVE_FAILED for it (wake.py `_check_quicksave`), status said `QUICKSAVE FAILED`, and the rate limit allowed the next
   call after `RETRY_S` 120 s, which would start a second save while the first still wrote.
4. **Proven: nothing looked at the save folder again.** A folder that landed at second 130 stayed a failure in
   `quicksave.json` for good.
5. **Not decidable offline: why the Run 13 call found nothing.** Three explanations fit the note: (a) the save needed more
   than 122 s and landed later (the fix reports and corrects it), (b) DF dropped the request because an autosave slot was
   busy (nothing is ever written; the fix says "DF started no save: save/current stayed empty"), (c) DF was frozen and the
   command had not been served yet (the fix keeps waiting while a file in `save/current` is fresh; with none it ends at
   `wait_s`).

## Fix
- **Wait:** base wait `save.wait_s` 180 s (was 120); while a file below `save/current` is younger than 60 s
  (`supervise.writing`: DF fills the folder during a save and empties it after the move) the wait goes on up to
  `save.max_wait_s` 600 s (`--timeout`, `--max-wait`, config/baseline.json `save`, `lint --config`); a fresh folder gets
  its 3 s to settle even past the base wait. tools/run_watch.py waits 900 s for the CLI (was 300).
- **Results (record `state`, `kind`, `limit`):** `ok` (`quicksave`); `running` (`writing`: still writing at the limit,
  exit 4, `QUICKSAVE_RUNNING: ...`, no wake, status `QUICKSAVE RUNNING`); `failed` with `call` (dfhack-run failed), `silent`
  (`DF started no save: save/current stayed empty`) or `vanished` (a running save stopped without a folder).
- **Settle:** `save.settle` (every `dfllm save`, follow for a `running` record) looks again: a folder that landed makes
  the record `ok`, `kind late`, `late` = seconds after the end of the wait ("written 130 s after the call (late: the
  wait had ended at 30 s)") and `dfllm save` returns 0 without a second quicksave (only a folder written within 600 s
  after the end of the wait counts as that call's save: the next yearly autosave an hour later does not); a `running` record that DF stopped
  writing 120 s after the wait ended becomes `failed`/`vanished` and wakes.
- **No second save:** refused (exit 3) while a file below `save/current` is younger than 60 s ("DF is writing a save
  (save/current: 3 file(s), newest 4 s ago): an autosave or a quicksave is in progress"); and when a verified autosave of
  this fort is younger than `save.autosave_fresh_s` 300 s the call returns 0 with "not needed: 'autosave 2' saved the fort
  80 s ago" (run_watch asks at the year start, right after the yearly autosave); `--min-gap 0` forces a quicksave.

## Not decided offline (live data that decides it)
Which of 5(a)-(c) happened in Run 13. Read-only, after the next such call: `<save>/quicksave.json` (`state`, `kind`,
`secs`, `late`, `limit`), `<save>/cli.log` (the `QUICKSAVE_*` lines and the settle line), and `dir "%APPDATA%\Bay 12 Games\
Dwarf Fortress\save"` with timestamps: a folder newer than the call (`late` > 0) = (a); `kind silent` with no folder
afterwards = (b); `kind writing` = the wait was too short for this world (raise `save.max_wait_s`). With BUG-070's
`inspect perf` gaps: a gap of the call's second tells whether DF froze (c).

## Tests
`tests/test_save_wait.py` (new, 11): a 250 s save is followed to the end; a save still running at the limit is `running`
(exit 4, no wake, status line); a silent failure and a failed call have their own kind and text; no quicksave while
`save/current` is fresh; a fresh autosave is the save (and `--min-gap 0` forces); a late folder settles a failure (a save an hour later does not); a
vanished running save becomes a failure and wakes; limits from config and their validation; run_watch's timeout.
`tests/test_save.py` (two assertions follow the new texts).
