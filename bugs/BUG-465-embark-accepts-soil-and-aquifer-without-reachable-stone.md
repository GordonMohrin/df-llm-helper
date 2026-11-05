# BUG-465 embark rank/scan and the gate let a site with no reachable hard stone through
Status: fixed (offline, live-untested); open: the span is an estimate per panel class, the real aquifer levels are known only after the first aqshaft
Severity: critical (all four forts of the world's region1 had no hard stone for years)
Found: 2026-11-05, Run 16a-d (`runs/run-16a/FR-BUGS.md` "Aquifer-Ebenen z123/126/127 heavy+light gemischt unter very_deep Soil", "Embark-Panel light aquifer vs. tatsaechlich leicht ueber schwer"; Roadvises, Castletongs, Mazelanterns, Syrupobeyed alike)
Module: `tools/embark/checklist.lua` (`evaluate`, `ACCEPTABLE`, `HARD_REJECT`), `tools/embark/steps.lua` (`merge_tiles`, `gate`), `tools/embark/embark.py` (`rank_key`, `stone_tier`, `aquifer_text`, `make_spec`), `tools/embark/rules.json`

## Actual
Basementflew (world 21,7): 15 levels of very deep soil, the panel said 'light aquifer', in the fort light z126/127 over heavy z120-123. The `stone` criterion was red, but it was acceptable (`--accept stone --explore-first ...`, `best compromise` even printed that line), the NE quarter offered nothing better and the player took it: stone 0 for four years (traps, levers, mechanisms, coffins, mood stone, the aqshaft ring). Roadvises, Castletongs, Mazelanterns and Syrupobeyed had the same soil. The rank put such tiles among the others by verdict and number of fails, the scan summary showed the panel class only.

## Root cause
`checklist.lua` C.ACCEPTABLE contained `stone` (FR-08: any failed criterion could be traded off with a reason), `NEEDS_PLAN` only asked for a text. `embark.py` `rank_key` / `summarize` sorted by verdict, number of fails and score, so a site 15 levels above its first hard stone ranked like one with stone at the surface when the other criteria matched. The summary printed `aq=<class>` only; the panel class hides the span.

## Fix
- `stone` is not in `ACCEPTABLE` (Lua and Python); `C.HARD_REJECT` / `HARD_REJECT` name the reason, `embark.py --accept stone` and the gate refuse it ("a failed stone criterion cannot be accepted, choose another site"), `best compromise` has none for such a rectangle. `--waive stone` stays for an UNKNOWN depth, with `--explore-first`.
- `evaluate`: `rules.aquifer_span` (light 4, varied 6, heavy 8 levels, from Basementflew z120-127 and Roadvises z112-120) is added to the estimated soil levels: the stone item says "about N levels to the hard stone (S soil + about A of the light aquifer)", the result carries `stone_levels`, `aquifer_span`, `reach`; a stone warning loses `stone_score_per_level` (3) score per soil level beyond a pass (at most 20).
- `rank_key` sorts verdict, then the stone tier (pass, warn, unknown, fail) and the reach, then the fails; the scan summary and the sweep rows use it. `merge_tiles` counts the hovered tiles per aquifer class (`rec.tiles.aq_n`), `aquifer_text` prints `aq tiles: 9 none, 6 light, 1 heavy`, the span and `hard stone ~N levels down`.

## Tests
`tests/lua/test_embark_bug465.lua` (3), `tests/test_bug465_468_f29.py` (4), `test_embark.lua`, `test_embark_fix6.lua`, `tests/test_embark.py`, `tests/test_bug245_250_embark_tools.py` (updated: waive instead of accept).

## Live check
`python tools/embark/embark.py scan <tiles> --hover` on a very-deep-soil site: `fail=stone`, the stone item names the levels, `--accept stone` is refused. `rank` lists the sites with the nearest hard stone first.
Open: a world with every tile under deep soil has no embark at all (region1: NO/NW/SO quarters): choose another world / region. The span per class is a guess; calibrate `aquifer_span` against the first aqshaft of a fort.
