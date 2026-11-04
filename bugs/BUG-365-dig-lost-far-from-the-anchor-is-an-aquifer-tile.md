# BUG-365 dig_lost at a chunk 45 tiles from the anchor: an aquifer tile, not an offset
Status: fixed (offline, live-untested)
Severity: high (the fortcore blocked for good at 4-7 %)
Found: 2026-11-04, Run 16c i3 (Yawninggilt, 2 forts: A106_78_125_1 and 66,80,127), main 2fcd6e0
Module: `lua/dfllm/runner.lua` (lost)

## Actual
`c1a1a6f2733b589001 s1.dig chunk 8: designation at 111,80,124 lost without a damp report`, again at 111,80,123, then
`lost twice without a damp report: blocked` (dig_lost, PROJECT_BLOCKED). Anchor 66,80,127, the tile lies 45 tiles away; the
first fort of i3 had the same at x=61 for anchor 106,78.

## Root cause
- No offset bug (checked): `bp.emit` of stage 1 at 66,80,127 rot 3 puts exactly chunk 8 (pos 84,74,122) on 111,80,124 and
  111,80,123: it is the civilian stair column at v=45 (`fortcore.CIV = (0, 45)`, rot 3 runs v along +x), 7 stair tiles z119-z125.
  The fort is 35 x 52 tiles; a lost tile 45 tiles from the anchor is the stair.
- The designation was cancelled by DF on an aquifer tile (i3 gamelog: 56 x `Digging designation cancelled: damp stone
  located.`; manifest aquifer_levels [121,122,124], z124 is one). `runner.lua` `lost()` asks the announcement log
  (`cancel_reported`, newest 200 reports) for a DIG_CANCEL_DAMP near the stage; the first fort's report arrived as a REPORT event
  (`AQ_OBSERVE src report`), the second fort's did not (fights and caravan notices fill the log), so `why` stayed nil: "lost
  without a damp report", second loss -> dig_lost, which parks the project without the damp handling (observe mode, re-site,
  manifest breach).

## Fix
runner.lua `Q.lost_on_aquifer` + `lost()`: with no report found, the lost tile itself is read (snapshot.tile `aq`, the aquifer
flag of a REVEALED tile; a hidden tile answers nil, the flag is never read for it). An aquifer tile is damp stone: `why = 'damp'`
-> the existing handling (observe mode re-designates with the damp marker, else BREACH_STOP damp and a manifest breach for the
re-site). A lost tile without the flag stays dig_lost as before.

## Open
A lost tile that is hidden still counts as dig_lost. The report search window (200) is unchanged.

## Tests
tests/lua/test_bug365_lost_aquifer.lua (3; two fail on 2fcd6e0), tests/test_bug364_367_aquifer_core.py
(`test_chunk_8_far_from_the_anchor_is_the_civilian_stair_not_an_offset`).

## Live check
A fortcore stage 1 in an aquifer: a lost stair designation logs `damp stone at x,y,z designated again with the damp marker`
(observe) or PROJECT_BLOCKED `breach:damp`, never `dig_lost`.
