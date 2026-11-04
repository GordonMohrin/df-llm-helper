# BUG-358 three parallel fortcore projects: a plan's stage 1 is placed beside the fortcore already there
Status: fixed (offline, live-untested): placing a fortcore stage 1 while another stage 1 project exists is refused
Severity: medium
Found: 2026-11-04, Run 16d (i4 y372, `runs/run-16d/FR-BUGS.md` "Drei parallele fortcore-Projekte"), 16a, 16b, main 595364a
Module: `dfpilot/cmd.py` (first_core, _place)

## Actual
`status` listed c1a1a6a22834073701, c1a1a6a2298294158f and y372s0b0/y372s1b0 at once, two of them 'set aside' 34-50 days (i4);
i1: the first plan placed a second fortcore (y372s0b0 stage 3) beside the hand-placed one, parked 'breach:water' after
39 d; i2: 'zwei Projekte, beide gegen Aquifer', one 'queued behind' the other.

## Root cause
Occupancy (`cmd.occupancy`) refuses only overlapping tiles. A fortcore stage 1 at another anchor (a plan's `fortcore@S1` after a
hand placement, or two plans) overlaps nothing, so it was accepted; each such project digs, queues and holds a runner slot.

## Fix
`_place`: a `fortcore` stage 1 (not a retrofit) is refused with BpError when `first_core()` finds another stage 1 fortcore project
in <save>/bp (cancelled ones live in bp/.cancelled; projects of a discarded timeline, stale_bps, do not count; the id being placed
again is skipped). The message names the project and its anchor and gives the way out: build on it (stages 2-4 `site=same`) or
`bp.cancel` it (which takes back its dig designations since BUG-353) and place again. Stage 2-4 and retrofit are not affected.

## Tests (fail on 595364a)
tests/test_bug356_358_startup.py (refusal by S1 and by an explicit anchor, stages/retrofit/self not refused, cancelled is no core).

## Live check
`bp.place tpl=fortcore site=S1` with a fortcore on file: 'refused (not sent): fortcore stage 1: <id> (anchor [...]) is the fort's
fortcore already'; after bp.cancel of it the placement goes through.
