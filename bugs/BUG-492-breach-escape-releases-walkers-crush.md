# BUG-492 BREACH deadline escape lets a raise go while a citizen walks toward the bridge: crushed on B1
Status: fixed (offline, live-untested)
Severity: critical (a citizen dies on a moving bridge; found on main by the BUG-478 traffic test)
Found: 2026-11-05, round 30 verification of BUG-478 (`tests/lua/test_bug478_refuge_lever_traffic.lua` with BREACH, the army parked 25 tiles from B1 and the BUG-462 stream: citizen 323 crushed on B1 at +603; `runs/run-16d/FR-BUGS.md` BRIDGE_CRUSH soldier 26395 on B2 in Run 16d i4 has the same shape)
Module: `lua/dfllm/gate.lua` (`holders`, `M.CROSS_ESCAPE`, `M.STAND_TICKS`)

## Actual
BREACH, 0 or far hostiles, citizens (and soldiers) streaming over B1. The raise is held for every walker whose path enters the footprint within `CROSS_REACH` (13) steps (BUG-380 review). After `CROSS_HELD` (50 %) of the 900-tick deadline the "deadline escape" cut that to `CROSS_ESCAPE` (2) steps so a queue standing at the gate cannot keep the bridge down for good. At +540 citizen 323 walked 8 steps out: released, the pull went through, B1 moved for ~100 ticks (11 steps) and he stepped on it at +603 (BRIDGE_CRUSH).

## Root cause
`gate.lua holders`: the escape treated a walker like a standing unit. The queue it was written for (BUG-380 test 7) stands; a walker within 13 steps will be on the footprint before the bridge has finished moving.

## Fix
- `holders` keeps the last positions of the crossers (`rt[name].stand`, replaced on each call): past the escape a crosser farther than `CROSS_ESCAPE` but within `CROSS_REACH` steps still holds the raise while he walked within `STAND_TICKS` (25) ticks (a unit seen for the first time counts as walking); only units that stand are released. A stream that never leaves a gap now ends in GATE_FAIL `blocked` at the deadline, naming the units (the existing time-out with a reason), never in a crush.
- (BUG-493 shares the edit: DRILL times its raise like SIEGE/BREACH, `TIMED_MODES`.)

## Tests
`tests/lua/test_bug492_493_traffic.lua`: (1) BREACH, army parked 25 tiles from B1, the stream: nobody crushed, B1 rises behind 323 (+711); (2) a stream without a gap: nobody crushed, GATE_FAIL `blocked` naming citizens; (3) a standing queue still releases the escape, a walker 9 steps out holds it. Verified to fail on the old escape ((1), (2)). Existing traffic tests (380, 462, 478, 331) green.

## Live check
BREACH with citizens walking to the gate: kern.log `gate: B1 raise held N ticks: only units on the footprint, within 2 steps or walking within 13 steps hold it now`, no BRIDGE_CRUSH; a permanent stream: GATE_FAIL B1 `blocked` with the units named after the deadline.
