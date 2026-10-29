# BUG-292 `bp sites aqshaft` ranks nothing and every hand-picked column is refused
Status: fixed (offline, live-untested)
Severity: medium (Run 15 Inkintense: 'bp sites aqshaft' -> 'no ranking; name the shaft column'; bp.place at 76,56 / 79,57 / 75,57
-> 'overlaps project(s) y372s0b0')
Found: 2026-10-29, Run 15 round 2 (Inkintense FR-BUGS)
Module: `dfpilot/bp/sites.py` (rank, _aqshaft), `dfpilot/cmd.py` (Occupancy.clash, ORTH_TPLS)

## Actual
`sites.rank` refused any ranking for aqshaft (05dc764 sites.py:223). The refusals were no bounding box: replayed on the copied
bp files, 79,57 touched the fortcore's dug workshop floor 78-80,56,128 (the 8-neighbour touch rule, cmd.py:414); 50 of 660 columns
in x70-99 y44-65 were free, none of them where the player looked.

## Fix
`bp sites aqshaft` ranks columns: a public Z4 floor tile (not a stair, never on or below the refuge level) whose column and 4
orthogonal tiles are rock or unknown on every level below (p.depth; below the snapshot unknown), off the keep-out boxes and the
cavern/warm levels; score 1000 - 5/step to a stair - 2/unknown column tile + 40 when it passes a known aquifer level. bp.place S1
takes the best free one. An aqshaft clashes with other projects only orthogonally (its seal is its 4 orthogonal walls; a diagonal
neighbour is allowed: 56 instead of 50 free columns there); every other template keeps the 8-neighbour rule.
Review: replayed on the Inkintense bp files, all 53 ranked columns lay on placed room or fortcore floor and S1 found none
free (the shaft's own top tile clashed with the floor's project). Now the shaft's top tile on a corridor project's floor is no
clash (a WET_TPLS project's still is), and `cmd.rank_sites` passes `bp.sites.rank(free=...)`: only columns whose top is
unowned or fortcore floor and whose emitted shaft no placed project clashes with (ValueError when none is). There S1 is now
68,50,128.

## Tests
`tests/bp/test_bug292_aqshaft_sites.py` (ranking, aquifer bonus, cavern refusal, diagonal/orthogonal clash);
`tests/test_bug193_aqshaft_place.py` (S1 without a column now places the best one). Fail on 05dc764.

## Live check
`dfllm bp sites aqshaft depth=6 --fresh` lists 3 columns with 'passes aquifer level z130' once BUG-291 learnt it; `bp.place
{"tpl":"aqshaft","site":"S1","p":{"depth":6}}` is accepted. Uncertain: whether a shaft beside a room diagonally stays dry enough on
an aquifer level (DF water flows diagonally; the seal stops the source walls only).
