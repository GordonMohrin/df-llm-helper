# BUG-652 The refuge plug waits for reasons nobody logs, three of them wrong in a BREACH
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y438: BREACH 176863910, plug ordered 176867229 (3,300 ticks later, `near 1`, `breach 1`), no event or log line says what held it
Module: `lua/dfllm/seal.lua` (`plug_eval`, `M.plug`, `M.PP.note`, `M.PP.inside`)

## Actual
From the BREACH on the plug was asked every deep-defense / BREACH pass and returned `wait:*` silently; 77 -> 12 citizens died on the stair column 84,111,138 / 135 / 134.

## Root cause
`plug_eval` returned its reason to `siege`, which ignored it; nothing was logged. By the code and the log three waits can hold a late plug: (a) `hostile_in(refuge)` counts a hostile on the stair column above the foot (the refuge burrow includes the stair tiles; the dragons stood on 84,111,135 from 176865008) as 'inside', although the ring at the foot keeps it out; (b) `plug_occupied` returns 'someone on the stair' for the stream of 17 recalled citizens (recall done 176864209) for as long as one stands on the column or next to the foot, for ever; (c) a hatch the dragons broke makes `M.refuge_open` return 'open', and `wait:open way in` waits for a hatch ('an open stair needs a hatch first', BUG-336) that building destroyers break again. Before the BREACH the outside citizens held the plug for `out_wait + out_each x 17` = 12,000 ticks. The exact blocker in the y438 window (176863910 .. 176867229) is not provable from the logs: that is why the reason is logged now.

## Fix
`M.plug` logs every change of the wait reason as PLUG_NOTE `what=wait` (class C, `why`, `mode`, `near`, `eta`, `need`, `out`, `pre`; the numbers in brackets are not a new reason; at most one per `PLUG.note_every` 300 ticks). `M.PP.inside`: a listed hostile on the stair column above the foot is not inside (a hostile on the foot or in the room, and the unlisted count of sense, still are). A BREACH with an open way in orders the walls (closer `broken hatch`); SIEGE still waits for the hatch. A busy stair holds the order `PLUG.occ_max` (900) ticks, then it is ordered (a builder waits for a free tile); in a BREACH not at all; with a pre-plug only the gap tile counts.

## Tests
`tests/lua/test_bug651_653_preplug.lua` (5a), (5b), and the wait-event count in (3).

## Live check
The next BREACH with destroyers: PLUG_NOTE `wait` events with the reason; REFUGE_PLUG within one pass of the BREACH when nobody is on the foot. Open: (a) assumes the ring at the foot keeps a dragon on the column out (true for walls, not tested live); a builder next to a dragon on the stair is at risk.
