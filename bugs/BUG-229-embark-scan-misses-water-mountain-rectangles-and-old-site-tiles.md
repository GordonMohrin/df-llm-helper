# BUG-229 embark scan: all-water/all-mountain rectangles pass, old-site distances use the wrong tile
Status: fixed (offline, live-untested)
Severity: medium (a "match" of the site finder can be a rectangle DF refuses; an old fort can count 2 tiles too far)
Found: 2026-10-29, Run 15 embark on i2 (tool findings 3 and 4)
Module: `tools/embark/panel.lua`, `tools/embark/checklist.lua`, `tools/embark/steps.lua`, `tools/embark/rules.json`

## Actual
1. The DF site finder ignores "Cannot embark entirely on water or mountains.": its no-aquifer matches can be such rectangles.
   `scan` had no criterion for it: the refusal only matched the generic `cannot` id, the biome line was not read, and a refusal
   shown after the click (instead of the Confirm popup) left `site.read` waiting for a popup until it failed.
2. `world_site.pos` can be up to 2 tiles off the site's real world tile `global_min / 16` (Questmetal: pos 4,10, global_min
   6,12). `rules.json` `old_sites` only took a hand-entered world tile `w`, the value one copies from `pos`.

## Fix
1. `panel.lua`: popup id `water_mountain` for the refusal (it replaces the generic `cannot` for that sentence); `P.BIOMES`
   (the exact DF 53.16 biome captions) gives `rec.biome` and `rec.terrain` (mountain / water / land). `steps.merge_tiles` counts
   `tiles.terrain` and `tiles.mw`. `checklist.lua` criterion `terrain`: the refusal fails, 16 read tiles that are all
   mountain/water fail, all read tiles (fewer than 16) or the one hovered tile warn, otherwise pass; not waivable or acceptable.
   `site.read` records the reject without a click when the panel shows a refusal (`S.REFUSED`) and records it when DF shows the
   refusal after the click instead of the popup.
2. `checklist.site_world`: an old site may give `g` = its global embark tile (world_site.global_min_x/y, or the embark_pos_min
   its embark showed); the checklist uses `g // 16`, the same frame as the scanned rectangle (`emb_min // 16`). `w` is used only
   without `g`. `rules.json` `old_site_g_note` says never to take world_site.pos.

## Tests
`tests/lua/test_embark.lua` `BUG-229: ...` (4 tests: panel ids and biomes, the terrain criterion, a scan of an all-mountain
rectangle with the refusal on the panel and one with the refusal after the click, both rejected and the next candidate read,
old site by `g`); `tests/test_embark.py::test_bug229_rules_refuse_water_mountain_and_take_old_sites_by_global_tile`.
All fail on 5e9e719.

## Live check
`python tools/embark/embark.py scan WX,WY --tiles` on a site-finder match that is all mountain: the row is `reject` with
`fail=terrain` (and the run goes on to the next site, no "no popup after the click"). For an old fort enter
`{"name": ..., "g": [global_min_x, global_min_y]}` in `rules.json` and check that a scan beside it names it `at 0`/`at 1`.
