# BUG-843 the raw items dump counted but never showed an item: the 198 logs and the 7 phantom barrels stayed unexplained
Status: fixed (offline, live-untested)
Severity: medium
Found: 24.11. live look: `inspect what=raw key=items:logs` said 198 'unwalkable_tile' and the barrels dump 7 'no exclusion' without a single position, tile type or stockpile.
Module: `lua/dfllm/dfraw.lua` (`R.itemscan`, `R.sample_item`, `R.items`)

## Root cause
The dump kept counters only.

## Fix
Up to 10 sampled items (2 of every first reason, 3 free ones, then filled): id, tile, tile type and shape, liquid, building at the tile, stockpile (id, name, max_barrels), walk group, container, contents, all item flags by name, general refs, the exclusion reasons. Every read is a pcall (`?` where a field is unknown).

## Tests
`tests/lua/test_neu4_cancel.lua` (the i2 barrels dump carries the sample with an unwalkable and a free line).

## Live-Erwartung
1. `python -m dfpilot why items:logs --raw` on i1 prints a 'sample (10 items ...)' block: the lead reads the tile type / liquid / building / stockpile of logs on 'unwalkable_tile' and decides from it why they lie there (felled in water? outside the sealed perimeter? tree-top level?).
2. `why items:barrels --raw` on i2 shows the 7 'none (free as DF sees it)' barrels with position, stockpile and flags. NOT promised: the cause of either is not decided by this change.
