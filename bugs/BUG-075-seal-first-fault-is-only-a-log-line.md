# BUG-075 A fault inside the seal-first count logs one error line and nothing else
Status: fixed in 954ddb1 (offline, live-untested): the runner raises KERN_FAULT (A, module runner, `backoff_s` 0) once per
distinct message with util/cadence; `by` of KERN_FAULT is `any` in schema.py and contract.lua
Severity: medium (a silent degradation: this run goes on without seal first and the rebuild policy)
Found: 2026-10-17 (BUG-037 added the pcall), decided 2026-10-23 (DECISIONS 11)
Module: `lua/dfllm/runner.lua` (`begin_run`, `Q.fault`), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Actual
`begin_run` (BUG-037) wraps `focus(K)` in a pcall; on a fault it logs `seal first/rebuild failed, this run without them:
<err>` once per message and goes on with an empty focus. Nothing reaches events.jsonl: no `status` line, no wake.

## Cause
`runner.lua` (f17e2b3) `begin_run`: `K.log('error', ...)` only (the S.ferr dedupe). The event registry had no event a
module may emit for a caught fault: KERN_FAULT is `by = 'kern'` (a back-off), the other A events are about something else
(PROJECT_BLOCKED is per project, DECISION_NEEDED asks a question nobody can answer, DECISIONS 3).

## Fix
- `Q.fault(K, err)`: KERN_FAULT `{module = 'runner', err, n = runs that faulted in a row, backoff_s = 0}` with the message
  `runner: seal first/rebuild failed, this run goes on without them: <err>`; the file name stays, the install path is cut.
  util/cadence per message: the first goes out at once; a message announced in this episode is never repeated; a distinct
  one needs 7 game days and 10 wall minutes after the last announcement (`cadence.due`, tokens = the messages, at most 8
  kept); a run whose count works ends the episode (`cadence.quiet`: the times stay, the lists go), so the same fault coming
  back inside the cadence is not announced again either.
- Contracts: KERN_FAULT `by` `kern` -> `any` (schema.py, contract.lua), CONTRACTS §12 row, RULES §7 KERN_FAULT row edited in
  place (no line added); wake already knows KERN_FAULT (`dfllm doctor`), status shows class A events, doctor reads it.
  The kernel's own back-off events are unchanged.

## Not decided offline
What breaks `focus` live. The next fault names it in `d.err` (file:line and Lua's message); with it the cause can be
proved from the code. The live read: events.jsonl (type KERN_FAULT, `d.module` runner) and kern.log `seal first/rebuild failed`.

## Tests
`tests/lua/test_runner_c4.lua` (fail on f17e2b3): the BUG-037 setup (a later stage `focus` chokes on) gives one KERN_FAULT in
ten runs with class A, module runner, `backoff_s` 0, no install path; the log line stays once; the end of the fault ends
the episode; the same message inside the cadence is silent, after 7 game days and 10 wall minutes it is announced again;
a distinct message waits the cadence the same way.
