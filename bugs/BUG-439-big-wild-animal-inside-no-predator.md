# BUG-439 a wild woolly mammoth killed two citizens inside the fort without any PREDATOR / INTRUDER wake
Status: fixed (offline, live-untested)
Severity: high (loses citizens)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y373 autumn (DEATH #755/#756 `killed by woolly mammoth 26503 (STRUCK_DOWN)` at 53,112,138; `runs/run-16a/FR-BUGS.md` "BUG Wollmammut toetet 2 Zwerge")
Module: `lua/dfllm/sense.lua` (`predator`), `lua/dfllm/care.lua` (`mark_killer` call)

## Actual
Two citizens struck down in one step, pop 22 -> 20 in peace, no INTRUDER, no PREDATOR, threat 0.

## Cause
A mammoth has no LARGE_PREDATOR caste flag and `isDanger` is false for a wild grazer, so `sense.predator` ignored it. BUG-421 (round 23, `mark_killer`) marks a wild unit only AFTER it killed
a citizen - too late for the first (here the only) kills: both died in one step. The run's kernel probably predated BUG-421 as well (committed 05.11. 00:58; the kern.log of that stretch is rotated away,
no "killed a citizen: a wild danger from now on" line survives), but even with it the first kills cannot be prevented.

## Fix
`sense.big_wild(u)`: a wild unit with `body.size_info.size_cur` >= `M.BIG_WILD` (300000 cm3; a dwarf is 60000) on a tile that is not outside (inside the rock of the fort), never tame, fort-controlled,
citizen, resident, merchant, diplomat, visitor, caged, chained or invader, counts as a predator candidate (census `pr` 1): the existing rules apply (citizens' walk group, PREDATOR wake, ALERT,
sortie offer). The size is read first, so an ordinary unit costs no extra API call (test_kern_load). Under the open sky a grazer stays wildlife until it kills (BUG-421's mark).

## Tests
`tests/lua/test_bug439_big_wild.lua` (2).

## Live check
A big wild unit walking into the fort: PREDATOR wake / ALERT before it kills. Risk: noise from a large harmless beast wandering into a cavern branch of the walk group (the PREDATOR_FAR rules apply);
BIG_WILD is a constant (tune after a live look).
