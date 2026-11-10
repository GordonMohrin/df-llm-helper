# BUG-690 The embark accepts a site with no trees and its hard stone 5 levels down: 0 logs, 0 stone, 0 blocks at the start
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Rocksblush (world 28,13; accept.log `trees` with the reason 'Baumarmut ueberall in der Welt'): `no material for workshop: no rock, no blocks, no logs`, workshops, depot6 and both aqshafts waited, 6 of 7 adults idle
Module: `tools/embark/checklist.lua` (`C.evaluate`, `C.HARD_REJECT`), `tools/embark/embark.py` (`HARD_REJECT`)

## Actual
The scan showed trees none / scarce (item `trees` FAIL) and 'about 5 levels to the hard stone' (item `stone` WARN, not a fail). `--accept trees` cleared the only fail, so the site was taken. The fort had no tree to fell and no stone to quarry before the first dig; the first workshop, the depot and the shaft's plug all wanted material and nothing in the fort made any.

## Root cause
`checklist.lua` judged `trees` and `stone` separately; each alone is a trade-off a player may accept (FR-08, `C.ACCEPTABLE`), but together they leave no material source. `steps.gate` clears a fail only when it is named in `accept`.

## Fix
`C.evaluate`: new item `timber` FAIL when the `trees` item failed (the best tile is none / scarce) and the `stone` item is WARN or FAIL (the hard stone is not near the surface). `timber` is in `C.HARD_REJECT` and `embark.py` `HARD_REJECT` (never ACCEPTABLE, never WAIVABLE): `--accept timber` is refused, `--accept trees` leaves the `timber` fail standing (`site rejected (fails: timber)`), `best_compromise` skips such a rectangle. Trees none with stone at the surface (soil little / none), sparse trees and an unknown soil depth are unchanged.

## Tests
`tests/lua/test_embark_bug690.lua` (2), `tests/test_bug690_691_f44_start.py` (the spec, the two lists), `tests/test_embark.py` (HARD_REJECT = stone, timber).

## Live check
`embark.py scan` on a treeless rectangle with 'some' soil: item `timber` fail, verdict reject; `embark.py embark ... --accept trees --reason ...` ends `site rejected (fails: timber)`.
Open: the hover scan reads the deepest soil of its tiles for stone (BUG-411) and the best tile for trees: a rectangle with trees on one tile passes; whether the first trees are reachable from the wagon is not judged.
