# BUG-426 embark: a bare mountain with a brook in a gully is rated as having water
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-05, Run 16a i1 Manorsubtle (embark 18,22,7,6; `runs/run-16a/FR-BUGS.md`; logs `dfllm-runtime/r16a3-manorsubtle-site97/`): died of thirst
Module: `tools/embark/checklist.lua` (`C.evaluate` water, `C.mountain_dry`), `tools/embark/steps.lua` (`merge_tiles`), `tools/embark/embark.py` (`brook_text`)

## Actual
The scan said `brook=in ~24 steps` for a rectangle whose brook ran behind rock the fort could not reach (the brook lay about 8 tiles east, x102-106,
unexposed). A pure mountain rectangle has no soil and no aquifer: dfpilot has then 1-2 wells out of 7 and no farm, and free digging within 3 tiles of
open water is forbidden, so the water item `pass` was wrong; three i1 forts died of thirst.

## Root cause
`checklist.lua` water: `rec.water` => `pass` whenever a brook tile was hovered; nothing looked at the terrain, soil or aquifer of the same tiles.
`merge_tiles` counted mountain tiles only together with lake/ocean (`mw`) and kept no soil count.

## Fix
`merge_tiles` adds `tiles.mountain` and `tiles.soiled` (tiles with any soil); `C.mountain_dry(rec)`: aquifer none and every read tile mountain without soil
(a single panel: its own biome and soil). With a brook the `water` item is then a FAIL `mountain: no soil, brook in a gully` (acceptable with a reason, like
every `water` failure), so the rectangle ranks below one with soil and a reachable brook bank or a light aquifer. `embark.py` `brook_text` shows
`brook=in a gully (...) but MOUNTAIN: no soil, no aquifer` (`mountain_dry`, same rule); sweep rows keep the three tile counts.

## Tests
`tests/lua/test_embark_fix24.lua` (dry, soil, aquifer, land, merged tiles, ranking), `tests/test_bug426_428_embark.py`.

## Live check
`embark.py scan WX,WY --hover` on a bare-mountain rectangle with a brook: `water` fails, summary says `MOUNTAIN`; on soil + brook it passes as before.
