# BUG-580 Drills fail as `occupied:B1` after BUG-543 and `drill never` keeps R2 closed
Status: fixed (offline, live-untested)
Severity: high (readiness R2 and the pop ceiling hung on a drill that could not pass for traffic)
Found: 2026-11-06, Run 16c i3 Sealcertain y406-y410 (DRILL_RESULT `fails: occupied:B1` repeatedly, readiness `drill never`; `runs/run-16c/FR-BUGS.md`)
Module: `lua/dfllm/drill.lua` (`step`, `finish`, `check`, new `occupied_now`, `traffic_only`), `dfpilot/schema.py` (DRILL_RESULT `retries`)

## Actual
After BUG-543 the drill's raise waits for any unit moving within `RAISE_R` tiles. A soldier or citizen beside B1 at T+900 made the drill drop the bridge (`gate.drill_skip`) and measure `occupied:B1`: a failed drill. The retry waited a month, doubled on repeated fails, `drill never` kept R2 closed.

## Root cause
`drill.lua` `step` (the T+`RAISE_MAX` handling): the only answer to a bridge not up at T+900 was `skip_late`, i.e. dropping it. `finish` counted every non-pass as a failed drill (`streak_fail`, DRILL_FAIL at 2, doubled `retry_wait`), though `occupied:*` is traffic, not mechanics.

## Fix
- At T+900 a bridge whose raise waits for our own people (`gate.held_by`) is not dropped: the clock restarts from that tick (`reset_kpi`, the raise stays wanted and goes up the moment the units clear), up to `OCC_RETRIES` (2) times and only while T+900 lies within `OCC_WINDOW` (2100) of T0, so the whole drill fits `siege.DRILL_MAX`. kern.log counts the restarts; DRILL_RESULT carries `retries`; `settle` stays the settle phase.
- A drill whose only failures are `occupied:*` (`traffic_only`) does not count toward the failure streak (no DRILL_FAIL, no doubling) and the next automatic try comes after `RETRY_OCC` (7200) ticks, not a month.

## Tests
`tests/lua/test_bug577_580_audit_siege.lua` (BUG-580 x3): a pacer beside B1 at T+900: the clock restarts, B1 rises, `retries >= 1`, the mechanics pass; one who never stops: `occupied:B1` after 2 restarts, `streak_fail` 0, no DRILL_FAIL, nobody crushed; `traffic_only`. The BUG-543 drill tests pass unchanged.

## Live check
DRILL_RESULT `retries` 1-2 and `fails` without `occupied:B1`; readiness leaves `drill never` after the next drill; kern.log `drill: T+900, B1 (soldier N next to it) kept down by our own people: the clock starts again (1 of 2)`.
