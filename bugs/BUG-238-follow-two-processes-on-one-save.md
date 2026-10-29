# BUG-238 follow: two follow processes on one save (every audit snapshot audited twice, AUTO_FAIL 'unknown snap')
Status: fixed (offline, live-untested)
Severity: high (15+ false AUTO_FAIL wakes, status/brief showed `audit FAIL`, two writers of `.follow.json`)
Found: 2026-10-29, Run 15 Guildcleans (y372-y374) and Inkintense (y373)
Module: `dfpilot/wake.py` (`run()`, `.follow.lock`)

## Actual
A Monitor that ended left its `follow` child running (Inkintense: PID 37564); the session started a new follow beside it.
Both tailed the same events.jsonl: each SNAPSHOT_READY purpose=audit was audited twice; the kernel accepted the first
`audit` and refused the second with 'unknown snap' (readiness takes a snapshot once), which woke as AUTO_FAIL
(`AUTO_FAIL x5: audit s150209889-7 ... refused: unknown snap`, c=15 in `.follow.json`). cli.log showed `auto:audit` and the
`follow wake` lines twice in the same second. Nothing kept a second follow from starting.

## Fix
`run()` holds `<save>/.follow.lock` `{v, pid, start, hb}` for the save the follower is attached to (it follows a save
switch) and beats it every `FOLLOW_HB_EVERY_S`. A follow that finds the lock of another pid that lives
(`pid_alive`: OpenProcess/GetExitCodeProcess on Windows, never `os.kill`) with an hb younger than `FOLLOW_LOCK_STALE_S`
(3 x 10 s) prints `follow already runs (pid N, beat Ns ago) for <save>: this one exits; stop that one, or start this one
with --takeover` and exits 3 without polling or writing `.follow.json`. `follow --takeover` takes the lock; the old follow
finds another pid in the lock at its next beat, prints `follow: pid N took over <save> (--takeover): this one exits` and exits
without saving its state. A dead or silent owner is replaced without `--takeover`. The lock is deleted on exit only by its owner.

## Tests
`tests/test_cli_wake.py::test_bug238_*` (pid_alive; refused, dead pid, stale hb, takeover, refresh sees the new owner, release
keeps another's lock; a second `run()` exits 3 without polling; the taken-over follow exits; released on exit). All fail on 6dc0f19.

## Live check
Start `python -m dfpilot follow` twice for the same save: the second prints `follow already runs (pid N ...)` and ends;
`<save>/.follow.lock` names the first pid. `follow --takeover` in a new Monitor: the old process ends within 10 s (Task Manager /
`Get-Process python`), cli.log shows `lock ... holds .follow.lock` once per start, and every audit snapshot gets one `auto:audit`
line and no `unknown snap` AUTO_FAIL.
