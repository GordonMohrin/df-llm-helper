# BUG-849 A long-running CLI call wrote the session heartbeat only when it started: the dead-man could pause the game under an active player
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 live session, 24.11.2026: at 600-900 ticks/s the 24000-tick bound of the dead-man (`config/reflex.json` deadman.max_ticks; it fires once the heartbeat is min_s = 45 s old) is reached in 27-40 s; a call that blocks that long without a beat gets the game paused. Players worked around it with tiny `wait` timeouts.
Module: `dfpilot/session.py` (`Keepalive`, `keepalive`), `dfpilot/cli.py` (`main`, `_dispatch`)

## Root cause
`cli.main` touched session.json once, before dispatch (cli.py, `session.touch(save_dir, c)`). `dfpilot wait` already refreshes it every `alarm.SESSION_EVERY_S` (10 s) inside its loop, so a plain `wait` was not the gap (with the kernel reading the heartbeat every check_s = 5 s the worst case is ~15 s x 900 = 13500 ticks); `cmd ... --wait`, `plan`, `bp sites --fresh` and `audit` block for minutes with the single start beat, and `bp` / `audit` / `why` are not session commands at all.

## Fix
`session.Keepalive`: refreshes session.json every `KEEPALIVE_S` (15 s of a monotonic clock) on a daemon thread while the command runs (`tick()` is the testable step with injected clocks). `cli.main` runs every command of `KEEPALIVE_CMDS` (the session commands + `bp`, `audit`, `why`) inside it. Session commands always beat; `bp` / `audit` / `why` only EXTEND a session whose heartbeat is younger than 120 s at the start (a supervisor's look never creates one; `status`, `events`, `doctor`, `follow`, `supervise` never touch it). `DFLLM_NO_SESSION=1` and `wake.json session.on false` switch it off. The thread is a daemon: when the process is gone (killed, crashed, the session died) the beat stops with it and the dead-man's timeout applies as before.

## Tests
`tests/test_bug849_keepalive.py`: fake clock (no beat before 15 s, one per interval over a long call), a real thread beating during a blocked main thread and not after, extend-only (no session.json, dead 10-minute session, live session), the factory per command and the switch, `main` runs the command inside the context.

## Live-Erwartung
`python -m dfpilot bp sites --fresh` or `audit` running longer than 60 s while no `wait` loop runs does not end in a DEADMAN_PAUSE (session.json `wall` advances every ~15 s during the call). PROMISED for the CLI side offline; EXPECTED live: the kernel's check (check_s 5 s) sees the fresher heartbeat. Dead sessions: no refresh after the process is gone.
