# BUG-529 A hanging aqshaft (z124, 425 days) keeps its runner slot for ever; hospital and fortcore wait behind it
Status: fixed (offline, live-untested)
Severity: high (hospital and fortcore blocked for a year; only the player's bp.cancel freed them)
Found: 2026-11-06, Run 16a i1 Basementflew y402-y403 (`runs/run-16a/FR-BUGS.md` "BUG Haengender aqshaft blockiert die ganze Bau-Warteschlange"; aqshaft c1a1ada7c99f998b01 at z124 38 %, "ring has not moved ... kept (an open aquifer level)")
Module: `lua/dfllm/runner.lua` (`M.CFG.release_days`, `Q.slot_release`, `Q.release_scan`, `second` in the scheduler), `dfpilot/fairplay.py`, `dfpilot/wake.py`

## Actual
The shaft held a level (designated / open / watched), so `Q.idle_keep` exempted it from the set-aside rule (BUG-328) and `second()` (scheduler pass 1/2) returned false for it: it kept a first-pass slot for ever. BUG-444 only announced it (PROJECT_BLOCKED stalled, every 60 days) and the project kept its slot. The hospital and the fortcore waited as `queued behind c1a1ada7`; the player cancelled the shaft and the fortcore ran at once.

## Root cause
`runner.lua` `second()`: `if P.tpl == 'aqshaft' and M.AQ.holds(S.rt, P.id) then return false end` (BUG-191: a shaft with an open level keeps its slot so that nobody digs into a flooding level unseen). Nothing limited it in time. (The log of the run does not show how many slots the kernel had at that time; the fix does not depend on it: the shaft's slot goes to the next project in the queue.)

## Fix
A shaft that holds a level and made no progress (`R.ps`, the same clock as BUG-444) for `release_days` (default 60, config `runner.queue.release_days`, 0 = off) gives up its first-pass slot: `Q.slot_release` makes `second()` true, it queues with the stalled projects (second pass: it still runs when slots are left over and is measured as before, so an open level is not forgotten), and `Q.release_scan` raises one DECISION_NEEDED `project_released` (A) per release (`proj`, `n` days, `cause`, `cmds`: the `bp.cancel` and `bp sites aqshaft --fresh`), again every `stall_every` days while it stays so (PEACE only). It comes back by itself on progress (a ring tile moves). The kernel cancels nothing (an undo removes built work). `wake.released_hint` tells the player what to decide; RULES.md DECISION_NEEDED row, `fairplay.RUNNER_LIM`.

## Tests
`tests/lua/test_bug529_slot_release.lua` (one slot: bedrooms wait behind the stalled shaft, then run after `release_days`, one DECISION with the cancel command, again after `stall_every`, nothing cancelled; `release_days` 0 = old behaviour), `tests/test_bug528_531_f33.py` (hint, config limit).

## Live check
A shaft stalled 60 days: `events` shows DECISION_NEEDED `project_released`; `inspect what=projects` shows the others running, the row of the shaft `no progress N d: slot yielded`.
Open: the same exemption holds a seal in SIEGE, the refuge drink and a mood project; those have their own escalation (seal_stalled) and are not released. A fortcore `aquifer=pass` still waits for a passed shaft (`Q.aq_wait`); the DECISION is what ends that wait.
