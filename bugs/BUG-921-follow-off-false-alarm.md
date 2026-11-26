# BUG-921 FOLLOW_OFF false alarm: a live follow with a beat older than 60 s is reported OFF
Status: fixed (offline, live-untested)
Severity: medium (players restarted a living follow; the repeat key hid the real frequency)
Found: Run 17 i3 run-17c, 26.11., kernel 8c553a52. 7 FOLLOW_OFF in 3 h; `status` said `follow: OFF (last heartbeat 60s/61s ago)`, follow.err empty, every replaced follow lived (follow.out18..24 end in "DISPLACED ... took over"). Diagnosis `leitung/neu10/DIAGNOSE-follow-off.md` section 1, 4, 7.1-2.
Module: `dfpilot/files.py` (`follow_off`, `FOLLOW_STALE_S`, `FOLLOW_STUCK_S`), `dfpilot/alarm.py` (`sys_reasons`, `SYS_NEXT`), `dfpilot/doctor.py`

## Cause
`files.py` `follow_off` called any beat older than `FOLLOW_STALE_S` (60 s) "OFF" without asking whether the pid lives (`wake.pid_alive` exists since BUG-385); `alarm.sys_reasons` turned every "OFF" into the wake FOLLOW_OFF, whose next step is `follow --takeover`. A beat is late whenever follow's single thread sits in a long poll step (BUG-922).

## Fix
- `follow_off`: beat older than 60 s and the beat's pid ALIVE: `follow: SLOW (heartbeat Ns old, pid N alive[, busy in <step> N s]; no restart needed)`; older than `FOLLOW_STUCK_S` (300 s): `follow: STUCK (... alive but not progressing ...)`. Dead pid or a beat without pid: `follow: OFF` as before. A fresh beat whose step has run >= 30 s says `follow: busy in <step> N s (alive, beating ...)`.
- `alarm.sys_reasons`: OFF -> FOLLOW_OFF (at once, dead pid); STUCK -> FOLLOW_STUCK (own key, own `SYS_NEXT`: look at status first, takeover only if it stays); SLOW and busy wake nobody and give no takeover hint.
- `doctor`: SLOW / busy are information, not a problem. The dead-man pause is untouched (it reads session.json).
- Docs: RULES.md, docs/v2/CONTRACTS.md, docs/v2/NEU1-wecken.md.

## Tests
`tests/test_bug921_922_follow_beat.py` (SLOW with live pid and no wake up to 300 s, STUCK wake with its own key, dead pid and pid-less beat stay OFF, busy text); `tests/test_bug385_follow_lock.py` (dead pid pinned).

## Live-Erwartung
During an audit / autosave stall `status` shows `follow: SLOW ...` or `busy in ...` and `wait` does not return FOLLOW_OFF; no `follow --takeover` is needed. A killed follow still gives FOLLOW_OFF within the sys check interval. A FOLLOW_STUCK wake is not expected; if one comes, the line names the step and cli.log has `slow_step` (BUG-922). Unproven: the cause of 3 of 7 stalls (no audit, no freeze) and the 24.8 s gap at 10:15.
