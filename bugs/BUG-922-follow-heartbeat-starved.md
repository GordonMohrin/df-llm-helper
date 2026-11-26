# BUG-922 The follow heartbeat is written only from the poll thread and starves during long poll steps
Status: fixed (offline, live-untested)
Severity: medium (cause of the BUG-921 false alarms)
Found: Run 17 i3 run-17c, 26.11. FOLLOW_OFF 08:37:32 and 09:37:30: kern.log snapshot written 08:36:32 / 09:36:38, follow logs `auto:audit` 70 s / 75 s later (median of 33 audits: 2 s); both audits >= 30 s hit a FOLLOW_OFF. Diagnosis `leitung/neu10/DIAGNOSE-follow-off.md` section 2-3.
Module: `dfpilot/wake.py` (`Follower._step`, `_write_beat`, `_heartbeat`, `beat_thread_tick`, `start_beat_thread`, `poll`, `run`, `FOLLOW_BUSY_MAX_S`, `FOLLOW_STEP_LOG_S`), `dfpilot/files.py` (`_busy_text`)

## Cause
`wake.py` `_heartbeat` runs from `poll()` (every `FOLLOW_HB_EVERY_S` 10 s), the same single thread as `_on_snapshot` -> `_audit` -> `compute_audit` (reads the ~460 KB snapshot, topology audit, 70-75 s measured) and `apply_minimal(wait_s=5)`. One long step = no beat.

## Fix
- `poll()` runs its steps inside `Follower._step(name)`: stamps loop progress (monotonic, start and end of every step), remembers the running step, and a step longer than `FOLLOW_STEP_LOG_S` (20 s) writes `follow/slow_step` to cli.log with step name and seconds (the measurement for the stalls the diagnosis could not explain).
- `run()` starts a daemon thread (`start_beat_thread`, once per second `beat_thread_tick`): it beats every 10 s, but only while a step started or ended within `FOLLOW_BUSY_MAX_S` (240 s): a loop stuck longer gets no beat, so status turns SLOW and after 300 s STUCK. The beat carries `step` / `step_s` (what the loop is doing: "busy in audit 70 s"). The poll-thread beat stays (same writer, lock-protected). `--once` / `--max-s` runs start no thread.

## Tests
`tests/test_bug921_922_follow_beat.py` (beat thread beats inside a 70 s step and names it, silent when one step exceeds 240 s and beats again after progress, slow_step in cli.log, short polls log nothing).

## Live-Erwartung
During an audit `.follow.hb` keeps its 10 s rhythm with `step` "event SNAPSHOT_READY" (or the audit job) and growing `step_s`; `status` shows `follow: busy in ... N s` for steps >= 30 s. cli.log gets `slow_step` lines for every step > 20 s, also for the stalls without audit. Unproven: that the beat thread is not itself starved when the whole process stalls (the 10:15 24.8 s gap: a GIL-holding C call or an OS stall would still stop it; then SLOW appears, no OFF).
