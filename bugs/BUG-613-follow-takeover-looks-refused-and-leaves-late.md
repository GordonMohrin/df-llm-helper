# BUG-613 `follow --takeover` seems not to take over a running owner; the displaced follow answers events beside the new one
Status: fixed (offline, live-untested)
Severity: medium (the player restarts follow again and again, two followers answer every event for up to 10 s)
Found: 2026-11-09, Run 16b i2 Brotherarrow y412 summer d12 (R37: `follow --takeover` -> 'another follow owns this instance (pid 34132) ... this one exits', 'the old follow went on writing follow.log'), y413, y414 (K6: 'takeover does not override a running owner'; the YEAR_REVIEW wake 'came 75 days late')
Module: `dfpilot/wake.py` (`_Lock._step`, `run`)

## Actual
`follow --takeover` printed nothing when it took the lock. The only text the player saw in `follow.log` was the DISPLACED follow's exit line `another follow owns this instance (pid N); do not restart. It took over ...: this one (pid OLD) exits` (the same file, the two processes write it side by side: `...does not taWAKE y390 ...`). It reads like the new start was refused and the old one lives on. The same words were printed to the new start when the BUG-385 cool-down refuses it (`this one exits`), so the two cases could not be told apart. And the old follow read the lock only at its beat (`FOLLOW_HB_EVERY_S` = 10 s): up to 10 s with two followers.

## Root cause
- `wake.py` `_Lock._step`, first attach (about line 2185 before the fix): a successful takeover returned `None` silently; the cool-down refusal text and the displaced text (beat branch) used the same wording.
- `wake.py` `_Lock._step`, same dir: `refresh_lock` ran only when `now - self.beat >= FOLLOW_HB_EVERY_S`, so a displaced follow polled and answered up to 10 s more.
- Checked in the Brotherarrow logs (`cli.log` lock lines 1794239033, 1794240762, 1794244040; `.follow.lock` now: pid 14588, took 27668): every `--takeover` DID take the lock and the previous owner left; the pid 34132 of the R37 note was the owner that 27668 displaced at 17:12:42 (its exit line sits at `follow.log` 703). The ping-pong guards (BUG-385/474) refuse only a start of the same code whose start id displaced the owner.

## Fix
- A takeover prints `follow: TOOK OVER <save> from pid X (code ..., this one ...): that follow sees the new lock at its next poll and exits; this one (pid N) follows now` (and logs it).
- The displaced follow's line keeps its start and the exit code 4 (`do not restart`), then says `DISPLACED, not a failed takeover: pid N took over ... and keeps following; this OLD follow (pid OLD) exits`; the cool-down refusal says `NOT STARTED: the owner keeps following, this new start (pid M) exits` and names `Stop-Process -Id N`.
- `_Lock._step` reads the lock at every poll (`lock_owner`: one small file and one pid check per second); the beat only refreshes it.

## YEAR_REVIEW wake 75 d late: not a follow delay
`perf.csv` wall 1794242713 = tick 166924800 (the year start); `cli.log` wake `WAKE y414 spr d2 ... YEAR_REVIEW: year 413 done` at wall 1794242725 (12 s later, game day 2); `HELD y414 spr d78` at 1794243164. The wake was printed on time (`URGENT_GAME`, BUG-240); the player read it at d79 (STAND 17:55), i.e. a follow whose output is read by polling, not a Monitor. Nothing to change in the wake gate; the PLAYBOOK / starter prompt should say `Monitor` for follow.

## Tests
`tests/test_bug613_614_follow_status.py` (5 for BUG-613: takeover line, silence without an owner, displaced at the next poll, refused-start wording, exit code); `tests/test_bug385_follow_lock.py`, `tests/test_bug474_477_f29ops.py`, `test_bug238_*` in `tests/test_cli_wake.py` unchanged and green.

## Live check
`follow --takeover` over a running follow of the same code: the new one prints `TOOK OVER`, the old one prints `DISPLACED` within about a second and exits 4; `status` names the new pid; a second `--takeover` within 120 s prints `NOT STARTED`.
