# BUG-577 BREACH (DEFCON 1) is raised for a bridge that only waits for a dwarf standing beside it
Status: fixed (offline, live-untested)
Severity: high (a BREACH sends the civilians to the refuge and turns the fort over; four of them for two dwarves who walked off)
Found: 2026-11-06, Run 16c i3 Sealcertain y405-y407 (`runs/run-16c/FR-BUGS.md`: `breach: B1 not up at T+900` beside GATE_FAIL `B1 not up after 900 ticks (blocked: citizen 26133 next to it, citizen 26577 next to it, never raised onto them)`; `E:/DF-test3/dfllm-runtime/` kern.log / events read only)
Module: `lua/dfllm/siege.lua` (`failed_bridge`, new `citizen_held`), `lua/dfllm/gate.lua` (new `held_by`, `force_near`, `unblock`)

## Actual
After BUG-543 the gate never pulls a bridge up while a unit is on or beside its footprint (the raise waits for them, never onto them). Siege's `failed_bridge` at T+900 still counted such a bridge as failed: the bridge was not up, a hostile (cave dragons) lay within `NEAR_RAISE` (10) tiles, or the hold had just ended and the pull was queued but not yet taken (`gate.waiting` nil), so SIEGE went to BREACH with `gate_fail`. The bridge rose a moment later.

## Root cause
`siege.lua` `failed_bridge` (the `held` expression): a hold is excused only for citizens it would cut off (BUG-028), a rescue, or `gate.waiting == 'blocked'` with no hostile within `NEAR_RAISE`. A hostile 4-10 tiles away turned a citizen hold into a failure although the gate would not raise onto the citizen anyway (force goes ahead only within `force_near`, 3), and the gap between the end of the hold and the taken pull (`waiting` nil) was a failure at once.

## Fix
- `gate.held_by(name)`: (ticks held in all this want, who, n on the footprint) while our own people on or beside the footprint hold the raise; for `HOLD_GRACE` (600) ticks after the last left it answers `held so far, 'released', 0` (the pull is queued and taken); `unblock` stamps `r.ub`. `gate.force_near()` publishes the config value.
- `siege.citizen_held`: such a bridge is no failure for `CIT_HOLD` (1800) ticks of its hold, unless a unit stands ON the footprint (BUG-310, as before) or a hostile is within `force_near` of it (a real breach); kern.log names it once. Longer, or with a hostile that close, it is a BREACH as before.

## Tests
`tests/lua/test_bug577_580_audit_siege.lua` (3, the siege traffic test the defense change needs): citizen beside B1 ~1000 ticks and a hostile 8 tiles out: no BREACH, B1 rises after he leaves, nobody crushed; a citizen who never leaves: nobody crushed, B1 stays down, BREACH only after `CIT_HOLD`; a citizen ON the footprint: BREACH at T+900 as before and never raised onto him.

## Live check
GATE_FAIL `blocked` with citizens named and no `BREACH` event within 1800 ticks of the hold; kern.log `siege: B1 is held down for our own people (...)`.
Open: the gate still reports GATE_FAIL `blocked` at its own deadline (900) - only the BREACH is held back.
