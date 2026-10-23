# BUG-072 One quickfort place call with three food stockpiles took 68.6 s; the stage placed every pile in one call
Status: fixed in 954ddb1 (offline, live-untested): a `place` chunk with two or more food cells is applied as one quickfort
call per food cell, one per slice, in the chunk's order; the cells between them stay together; a pile that stands is not
placed again; each call's cost is logged. Whether a cheaper blueprint for one pile exists is not decided offline (below).
Severity: high (the runner froze DF for 68 s; BUG-039 bounded the damage, this removes the cause where the code can)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y451 winter d63 (BUG-039); decided 2026-10-23 (DECISIONS 7)
Module: `lua/dfllm/runner.lua` (`apply`, `Q.pile_part`, `Q.pile_stands`, `Q.food_cell`), templates `dfpilot/bp/rooms.py:337-340`
(stockroom), `:418` (refuge_drink), `dfpilot/bp/fortcore.py:146, 201`

## Actual (live, from BUG-039)
```
kern.log: 182157789 runner: y451s3b0 build: 2 manager orders, 2 items
          182164588 kern: runner demoted x4 (68603 ms; ...)
```
The slice that followed the build stage applied the stockroom's place chunk: one `quickfort place` call with three `f`
cells (a still at the far end splits the room into three piles, `rooms.py:337-340`).

## Cause
1. **Proved: one call holds every pile of a chunk.** `apply` (runner.lua before the fix) sent `chunk_data(ch)` whole, one
   `act.quickfort` per chunk; `abs_chunks`/the python templates put all the cells of a stage into chunks of up to 40.
   The stockroom with a still has three `f` cells in one chunk (`rooms.py:339-340`), so one call placed three piles.
2. **Probable (DFHack, not dfllm code; BUG-039 cause 2):** quickfort's `configure_stockpile` imports `library/cat_food`
   per pile (`internal/quickfort/place.lua:256-260`), and the food import copies all raw materials per element
   (`StockpileSerializer.cpp:479-484`, `OrganicMatLookup.cpp:28`): the cost per pile grows with the creature raws of the
   world, so three piles cost three times one pile. This is the DFHack source as the BUG-039 session read it; it cannot be
   re-read offline here.

## Fix
- `Q.pile_part(K, P, st, ch, R)`: a chunk with two or more food cells (a key with an `f`, `Q.food_cell`) becomes a list of
  calls in the document's order: each food cell alone, the cells between them together (an `u`/`w`/`s` pile stays with
  its neighbours). `apply` sends the next call and leaves `P.chunk` where it is until the last call is made; the next
  call goes in the next slice (one `qf` per slice: `qf_per_slice`, the existing slice and pacing guards). Progress is
  `m.runner p.<id>.pc = {c = chunk, n = calls done}` (new stage -> new record; a chunk index that no longer matches is
  ignored, so an old state starts the chunk again).
- Idempotence: a food cell whose first and last tile hold a stockpile building of its name (`name=` in the cell; any
  stockpile when the cell has no name) is skipped with an info line (`the food pile at x,y,z stands, not placed again`),
  also after a reload that lost `pc`. A chunk with at most one food cell is applied whole, as before (fortcore s1.place and
  s3.place, refuge_drink, a stockroom without a still: one pile each).
- Diagnostics for the live decision: every place call with food piles logs `<proj> <stage> chunk N[ call k/n]: quickfort
  place with F food pile(s) took MS ms (R creature raws)` (`getTickCount`, 15.6 ms steps; R = `#world.raws.creatures.all`,
  read only).

## Not decided offline
Other place templates: the stockroom is the only template with several food piles in one chunk (`grep '\.ent(.*"f"'
dfpilot/bp`: stockroom x3 with a still, fortcore s1/s3 one `f` each, refuge_drink one `f` with `:=booze`). A cheaper
form of one pile (a stockpile configured by its category flags in the blueprint line instead of the `f` key's full
`cat_food` import) cannot be proved equivalent without the DFHack quickfort source and a live call; the `f` key's meaning
and the `:=booze` preset are quickfort's, and a configuration string is applied on top of the key's import, not instead
of it as far as the user guide says. Deciding live data (read only): the new log lines on the next stockroom, refuge_drink
and fortcore place stages (ms per call against `creature raws`), and `dfhack-run quickfort list` is not needed. If one
pile still costs seconds, write the FR with those numbers.

## Tests
`tests/lua/test_runner_c4.lua` (all fail on f17e2b3): a stage of three piles is three calls in three frames in the
document's order and the project ends done; a mixed chunk (`u`, `f`, `w` + `s`, `f`, `g`) is five calls with the
between-cells together, a chunk with one food pile stays one call; a pile that stands (corner tiles, its name) is skipped
and one of another name is not; a reload between two piles continues with the third (`pc` persisted).
