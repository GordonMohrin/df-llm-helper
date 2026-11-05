# BUG-474 `follow --takeover` was refused after a deploy: live forts kept running OLD CODE
Status: fixed (offline, live-untested)
Severity: critical (a deploy did not reach the forts that run; `status` showed OLD CODE for hours)
Found: 2026-11-05, Run 16 (i1, i3, i4; `runs/run-16c/FR-BUGS.md` "follow --takeover: 'another follow owns this instance (pid 19612) ... this one exits'"; 16b i2: two follows in parallel, pid 25008 + the new one)
Module: `dfpilot/wake.py` (`acquire_lock`, `other_code`, `_Lock._dup_check`)

## Actual
After a deploy the player started `dfllm follow --takeover`; it answered `follow: another follow owns this instance (pid N); do not restart` and exited 4. The old follow (OLD CODE) stayed. On i2 two follows ran side by side and answered every event twice.

## Root cause
`wake.py` `acquire_lock` (BUG-385 guards): a takeover is refused when the owner took the save over less than 120 s ago (cool-down) or when the owner took it over from "this very start" (`took_from_me`: same pid, or same start id). The start id is `DFLLM_FOLLOW_SID`, else the parent pid, and every follow an agent starts from one shell / one Monitor shares that parent: the owner (old code, itself a takeover) named a `took_sid` equal to the new start's id, so every later deploy start looked like the displaced start coming back and was refused for ever. The guards exist for two starts of the SAME code that restart each other; a deploy is the opposite case. The second symptom: a follow from before BUG-238 never reads the lock, so it cannot be displaced and ran beside the owner unseen.

## Fix
- `acquire_lock`: an owner that runs OTHER code than this process (`other_code`: its lock `code`, else its `.follow.hb` code, else no code at all = older than BUG-334) is displaced by a takeover whatever the cool-down and the start id say, unless it took the save over from a follower of MY code (`took_code` == CODE: the old code coming back, the real ping-pong). The lock now records `took_code` (kept by `refresh_lock`).
- The displaced old follow exits on its own at its next beat (`refresh_lock` sees another live pid with a fresh heartbeat): no kill.
- `_Lock._dup_check` (every beat): a foreign pid that keeps beating `<save>/.follow.hb` for `FOLLOW_LOCK_STALE_S` beside the owner ignores the lock (code from before BUG-238) or is a second copy: one line naming the pid and `Stop-Process -Id <pid>`, once per pid, logged as `follow dup`. Nothing is killed from here.

## Tests
`tests/test_bug474_477_f29ops.py` (takeover over an old-code owner with the same start id, no-code owner, same code still refused, other code coming back refused, `took_code` kept, `run` end to end, duplicate pid said once); `tests/test_bug385_follow_lock.py` (the old-code cool-down test now sets `took_code`).

## Live check
After the next deploy: `dfllm follow --takeover` prints "ran OLD CODE ... taken over" (or holds the lock silently) instead of "owns this instance"; `dfllm status` loses OLD CODE within one beat (10 s); the old pid is gone. If `follow dup` appears in `cli.log`, a pre-BUG-238 follow is still alive: stop that pid.
Open: a follow older than BUG-238 is only reported, not stopped.
