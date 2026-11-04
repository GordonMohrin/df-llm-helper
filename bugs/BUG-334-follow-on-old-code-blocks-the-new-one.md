# BUG-334 a follow on old code blocks the new follow; the players must know --takeover
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15 (Earthboat round 4, Inkintense and Drillchamber rounds 2-5)
Module: `dfpilot/wake.py` (.follow.lock, `_Lock`)

## Actual
Earthboat FR-BUGS round 4: `follow already runs` (old code, pid 22684), no `--takeover` (a process the player had not
started), so the player watched by polling status/events. Inkintense round 2: status said `follow: OLD CODE` before the player
ran `follow --takeover`; Drillchamber did the same in round 5.

Root cause: `dfpilot/wake.py:1351-1359` and `_Lock._step` (9b6f614): BUG-238's lock refuses any live owner with a fresh beat,
the same for an owner that runs code from before the last update (BUG-042's OLD CODE, which status already detects from the
heartbeat's `code`). Only `--takeover` moved on.

## Fix
The lock carries the owner's code stamp (`code`, files.code_stamp, written by acquire_lock and every refresh). A new follow reads
the owner's code (the lock's, else the owner's fresh `.follow.hb` `code`: followers from before this fix) and, when it differs
from its own CODE, takes over by itself: stdout and cli.log `follow: pid N ran OLD CODE (<old>, this one <new>): taken over, it
exits at its next beat`. The old one exits at its next beat (BUG-238 refresh_lock, unchanged). The same code: refused as
before; the line names the command `dfllm follow --takeover`.
Review fix: only a long-running follow takes over by itself; `follow --once` / `--max-s` (a one-shot) is refused (exit 3)
like the same code, else it polled beside the old follow, ended it at its beat, then released the lock and left no follow.

## Tests
`tests/test_bug334_follow_old_code.py` (7; the takeover and the lock's code fail on 9b6f614; the two one-shot cases fail
before the review fix).

## Live check
After the update: a new `dfllm follow` beside a running older one prints the OLD CODE takeover line and runs; within ~10 s the
old process ends (Task Manager), status shows no `follow: OLD CODE`. Uncertain: a follow started from another checkout (other
mtimes, other stamp) takes over the main one as well (by design: the newest started follow wins).
