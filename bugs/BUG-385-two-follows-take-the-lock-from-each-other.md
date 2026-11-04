# BUG-385 two follows with --takeover on one instance take the lock from each other, status names no owner
Status: fixed (offline, live-untested): a takeover is allowed once per cool-down; the loser exits and does not take it back; status and doctor name the owner pid
Severity: medium
Found: 2026-11-04, Run 16b (i2, `runs/run-16b/FR-BUGS.md` "OBS follow --takeover: auch 2. und 3. Start wird von fremder pid 17492 uebernommen")
Module: `dfpilot/wake.py` (acquire_lock, refresh_lock, _Lock), `dfpilot/files.py` (follow_off, follow_owner), `dfpilot/doctor.py`

## Actual
i2: the player's `follow --takeover` was "taken over by pid 23632", after the restart again by pid 17492. `cli.log` of region1-site97
holds four `lock {"takeover":true}` lines within 80 minutes. The lock is per runtime folder already (`<runtime>/.follow.lock`), so two
starts on that folder (the Monitor that restarted follow after "took over, this one exits" plus a new start) fight: each start with
`--takeover` takes the lock, the other exits at its next beat, its Monitor restarts it with `--takeover` again. The message
named a pid and nothing else; status did not say which pid beats.

## Root cause
`dfpilot/wake.py` `acquire_lock` (:1506): `--takeover` (and BUG-334's old-code takeover) took the lock whenever a live owner stood
in it, with no memory of a takeover that had just happened, and the file was not read back after the write (two starts at the
same moment both believed to hold it). `refresh_lock` (:1526) rewrote the lock at every beat without the takeover record.
`files.follow_off` knew no pid.

## Fix
- The lock records `took` (the pid taken over) and `took_at`. `acquire_lock` refuses a takeover of an owner whose `took_at` is
  younger than `FOLLOW_TAKEOVER_COOL_S` (120 s): returns `(False, owner + cooldown)`; follow prints "follow already runs (pid X took
  ... over from pid Y N s ago): this one exits and does not take it back ... stop the other start" and exits 3. The first (newer)
  start wins once, the older exits at its next beat (message with both pids), nobody takes it back.
- `refresh_lock` keeps `took/took_at` across beats; `acquire_lock` reads the lock back after the write and loses when another pid stands in it.
- follow's heartbeat carries `pid`. `files.follow_off` names it ('follow pid N: OLD CODE', 'OFF (..., was pid N)'); new
  `files.follow_owner` and a doctor line 'follow: pid N (beat 4s ago, took over from pid M 17s ago)', a problem line when the lock and
  the heartbeat name two pids.

## Tests
tests/test_bug385_follow_lock.py (8).

## Open
A wrapper that restarts a refused follow every few seconds still starts a process each time (it exits at once, exit 3).

## Live check
Two terminals, `dfllm follow --takeover` in each: the second wins, the first exits ("took over ... does not take it back"); starting the
first again within 2 min prints "follow already runs (pid .. took ... over)" and exits 3, the second keeps beating; `dfllm doctor`
shows `follow: pid N (beat .., took over from pid M ..)`.
