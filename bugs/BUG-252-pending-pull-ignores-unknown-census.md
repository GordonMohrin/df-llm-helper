# BUG-252 A pending pull went ahead while the census was unknown
Status: fixed (offline, live-untested)
Severity: high (nobody could say who stood on the footprint, the pull went on blind)
Found: 2026-10-29, Run 15b Earthboat (code review of the crush, BUG-251), fix6-crush
Module: `lua/dfllm/gate.lua` (`control`, pending path)

## Actual
`holders()` marks `hold.unknown` when the unit scan is nil (no census), and the queue path waits for it ('census'), but the
pending path checked only `#hold > 0`: a pull queued before the census went away stayed pending and the bridge moved without
anyone checking the footprint.

## Fix
The pending path cancels our pull while the census is unknown (stale 'census'): no give-up count (only 'blocked' counts toward
gate.pull_cap), no GATE_FAIL; the queue path queues again once the census is back.

## Tests
`tests/lua/test_gate_crush.lua` `BUG-252: ...` (fails on 2b9c009).

## Live check
Hard to provoke live (a census gap after a load or a kernel fault): no LEVER pull completes while `inspect census` has no `u`;
a cancel_own_lever_job ACT right after such a gap.
