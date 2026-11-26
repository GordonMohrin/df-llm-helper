# BUG-934 The wood pile (BUG-926) gives up with "no 5x5 plain floor within 12 tiles": smaller piles and a wider search first
Status: fixed (offline, live-untested)
Severity: medium (i1 Diedplank: felled logs lie 50+ tiles from the carpenters, no pile ever placed)
Found: Run 17 i1 Diedplank, DECISION_NEEDED #17716 wood_pile "no stockpile with room takes wood within 40 tiles of the Carpenter's workshop at 94,96,144 and none could be placed (no 5x5 plain floor within 12 tiles of carpenter 94,96,144)"
Module: `lua/dfllm/economy.lua` (`T.woodpile`, `M.pile_site` option `cache`), `config/baseline.json` (`economy.wood.pile_min`, `pile_r2`)

## Cause
- `T.woodpile` called `M.pile_site` once per shop with the full `pile_w` x `pile_h` (5 x 5) and `W.r` 12: a fort whose indoor floor beside the carpenters is cramped had no 25-tile block within 12 tiles, and the question stood (the player cannot free a 5x5 on demand).

## Change
- Sizes from `pile_w` x `pile_h` down one tile a step to `wood.pile_min` x `pile_min` (2): 5x5, 4x4, 3x3, 2x2; the search radius 12, and once per `every` (28) days also `wood.pile_r2` (24, at most 40); the first fit (biggest size at the nearest ring) wins. The tile reads are shared between sizes (`q.cache` in `M.pile_site`). Same rules as BUG-926: indoor (roof read fails closed), dry, plain floor, citizens' walk group, off the attack path, no tile of an existing stockpile / zone or a refused site, nothing dug, PEACE only. WOOD_PILE `placed` and the log line carry the size that was placed (`w`, `h`); the DECISION_NEEDED says `no WxH plain floor within R tiles` with the smallest size and the widest radius tried, and asks for `pile_min` x `pile_min` floor.

## Tests
`tests/lua/test_bug934_wood_pile_small.lua` (4: a 3x3 only, 2x2 as the minimum / pile_min 3, 18 tiles away found by the wide search / 30 tiles not, the safety rules for small piles); `test_bug910_915_holz.lua` shop moved beyond the wider search.

## Live-Erwartung
i1: WOOD_PILE `placed` with a smaller `w` x `h` or at a position up to 24 tiles from 94,96,144, or the DECISION_NEEDED text naming `no 2x2 plain floor within 24 tiles`.

## Not proven
- That haulers bring logs to a 2x2 pile (4 tiles) fast enough: a small pile fills at once, then DF's haulers need another pile (BUG-926's open question).
