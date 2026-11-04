# BUG-405 trap project blocked by a corpse on the build site
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16b (i2 Ostgate y397 sum, `runs/run-16b/FR-BUGS.md`), main 503bb8b
Module: `lua/dfllm/economy.lua`

## Actual
Trap at 88,101,130 (project y397s0b0): job 158133 'suspended by DF ... 1 corpse', stalled 36 d at traps.build 75 %, DECISION build_blocked.
The kernel counted the corpse and left it (burial's); nobody hauls a corpse nobody marked, the builder cancels 'Item blocking site'.
The player cancelled the project.

## Root cause
`economy.lua` `site_items` (daily `jsite`): corpses and dead dwarves' items were only counted (`s.corpse`), never unforbidden or marked
for dumping, so a stranger's (enemy, animal) corpse on a footprint blocked the building for good. Care dumps strangers' corpses only
within `approach_r` of the approach boxes.

## Fix
`site_items` queues a corpse or corpse part on a footprint that is not a dead dwarf's item, not a mood-reserve hold and belongs to a
unit that is neither own group nor citizen (`M.stray_corpse`, false when the unit is unreadable); `jfree` unforbids it and sets
`dump` (the haulers carry it off, the next `jresume` follows). A citizen's body stays care's (burial). JOBS_SUSPENDED names the count.

## Open
Without a garbage dump zone a dump-flagged corpse is not hauled (trash.lua keeps one); picking another tile (re-place) is not done.

## Tests
tests/lua/test_economy_sites.lua (stranger's corpse dumped and unforbidden, citizen's body and unreadable unit stay).
