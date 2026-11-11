# BUG-701 A supervise.lock whose pid is dead blocks `supervise --load` for an hour
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10 23:10, Run 16b i2 (lock `40628 1794348642`, pid 40628 not running; `--load`: 'another supervise run holds supervise.lock (a restart chain is running)' for an hour)
Module: `dfpilot/supervise.py` (`_run_lock`, `pid_alive`, `lock_pid`)

## Root cause
`_run_lock` judged a lock only by its mtime (`LOCK_STALE_S` = 3600), though the lock file holds the owner's pid.

## Fix
`_run_lock` reads the pid (`lock_pid`) and treats the lock as stale at once when `pid_alive(pid)` is false (Windows: `OpenProcess` + `GetExitCodeProcess` == STILL_ACTIVE, access denied = alive, unknown = alive; elsewhere `os.kill(pid, 0)`). A lock with no readable pid keeps the 3600 s rule; a live pid is never taken over before the age limit.

## Tests
`tests/test_supervise.py`: `test_run_lock_dead_pid_is_stale_at_once`, `test_pid_alive_real_processes`; `test_run_lock` and `test_check_version_does_not_race_a_running_pass` now lock with the test's own live pid.

## Live check
Kill a supervise run mid-chain, run `supervise --load` at once: it proceeds. Open: a recycled pid of an unrelated process keeps the lock until the age limit.
