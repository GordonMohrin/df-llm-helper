# BUG-310 A forced raise went ahead with units on the bridge ('next to' and 'on' treated alike)
Status: fixed (offline, live-untested)
Severity: critical (a forced raise could fling or crush a unit on the bridge; the two y379 BRIDGE_CRUSH were most likely misattributed, see Review)
Found: 2026-10-29, Run 15b Earthboat (y379 summer, BREACH #3616), fix11-gate-crush
Module: `lua/dfllm/gate.lua` (`holders`, `forced_event`, `control`)

## Actual
events #3630/#3655/#3723 `GATE_FORCED B2 raised onto citizen 26600 next to it: a hostile 3 tiles from it (force_near 3)`. Pull
152940523 stayed pending 490 ticks (`B2 pull taken 12 ticks after queueing` at 152941013, `B2 moving up with citizen 26424 next to
it`), then #3751 citizen 26276 and #3757 citizen 26424 crushed (152941133/152941168). Root cause: `holders` (gate.lua:1213 on 9ef2ccb)
returned the force for every unit within the 1-tile margin, on the footprint or beside it, and the pending check (gate.lua:1767)
only emitted GATE_FORCED instead of cancelling, so nobody stepping ON the footprint during those 490 ticks held the raise. The named
unit 26600 was the pull's own worker at lever 56,80 (lever pullers dfllm-levers-b2 = {26558,26600}), so the text read "raised onto"
a dwarf who was only beside it.

Review (events.jsonl/kern.1.log of r15-earthboat, read-only): neither victim was ever seen ON the footprint. The move record (opened
at 152941013, per-frame positions while it moved) had 26424 at 1 tile and 26276 at 2 tiles at their closest, and there was no
GATE_CRUSH_RISK for that move. DF's incident for 26424 said BLEED at 55,82,132, six levels below the bridge (care's DEATH #3758:
bled). 26276 was missing from the unit list, cause unknown. A goblin was killing citizens at the bridge at the same time (#3724
26649 bled at 55,81,138, 25 lost in that BREACH). So the two BRIDGE_CRUSH were most likely misattributed: gate's `unit_death`
skipped only `killed` incidents and matched a unit seen within 2 tiles, while care already let the incident decide. The hole in
`holders` is real (a forced raise ignored units on the footprint) but these logs do not show that it killed anyone.

## Fix
`holders` splits a forced raise's units: on the footprint (d 0) they hold it like any unforced pull (queue path and every frame of a
pending pull: cancel, `GATE ... waits`, pull_cap give-up), next to it they are passed and named. GATE_FORCED is emitted once per job
from the pending check when the worker is known, without him, as `<B> raised with <units> next to it: ...`. An unknown census holds a
forced raise too. RULES §7 row and CONTRACTS row GATE_FORCED: units are the ones next to the footprint.
BRIDGE_CRUSH (`unit_death`): a death whose incident names another cause (BLEED, ...) counts for the bridge only for a unit
seen on the footprint (d 0); RULES/CONTRACTS rows BRIDGE_CRUSH.

## Tests
`tests/lua/test_siege.lua` `BUG-310: ...` (two scenarios, fail on 9ef2ccb). `tests/lua/test_gate_footprint.lua` `BUG-310 ... BLEED` (fails on 4ff6a8a).

## Live check
At the next SIEGE/BREACH raise with a hostile at the gate: `dfllm events --type GATE_FORCED` says `raised with ... next to it`,
never a unit on the footprint; kern.log `gate: B2 up waits for ... on the footprint` while one stands on it, and no BRIDGE_CRUSH
with `last seen on it`. Uncertain: whether a unit that steps on during the ~100-tick move (after the lever is pulled) can still be
crushed; GATE_CRUSH_RISK (B) names that case.
