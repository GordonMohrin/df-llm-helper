# BUG-247 embark local.place: the held pixel runs out of the window; no scan without the rectangle
Status: fixed (offline, live-untested)
Severity: medium (scan and embark abort at local.place; the player places by hand and loses the gate)
Found: 2026-10-29, Run 15d Drillchamber (i4, window 174x75 tiles), `scan 13,11 14,11 15,10 9,7 10,6 --tiles`
Module: `tools/embark/steps.lua` (`S.place`, `mouse_ready`, `hold_pixel`, `S.enter_placing`, `S.hover_tile`,
`S.hover_record`, scan `hover`), `tools/embark/embark.py` (`scan --hover`)

## Actual
16x "rectangle does not follow the mouse: held 933,576 and 437,-16, rectangle stays at 244,219", the held pixels ran ever more
negative (... -7083,-9104), abort at local.place (34/180), 0 panels read. Without the cached cursor over the map the loop
moved the HELD PIXEL by the learnt k and learnt k again from every miss. On i4 the rectangle followed only the first hold after
a camera change (measured: rectangle corner = camera - (23,12)); the panel always followed the mouse.

## Fix
One fixed pixel per run (the probed OS cursor when it lies over the map, else the middle of the window's centre tile); only the
camera moves: camera = target - k - floor((P - C) / 16). A miss counts when the same camera shows the same wrong rectangle on
two checks; the first measures k once (|k| <= `local_k_max`, default 48, else the rectangle does not follow at all), the second
fails at once naming both holds and pointing to `--hover`. `scan --hover`: per candidate the "Embark" button, then 16 hovered
tiles (camera so the fixed pixel hovers each tile of the 4x4 grid, `hover_k` offset), each panel read twice alike, merged into
one row (`hover`, no size); the hovered tiles' records are kept as `parts` (embark --here, BUG-250).

## Tests
`tests/lua/test_embark_fix6.lua` `BUG-247 ...` (i4 geometry with a rectangle that follows only camera changes: placed, one
held pixel, k = -23,-12; a second miss fails at once; hover scan with a rectangle that never follows); `tests/lua/test_embark.lua`
BUG-020 test updated to the new rule (the held pixel stays in the window, no k learnt); `tests/test_bug245_250_embark_tools.py`.
All new tests fail on 6dc0f19.

## Live check
On i4 (174x75): `embark.py scan 9,7` shows `local.place` lines "camera X,Y, holding P" with ONE pixel, then either the rectangle
on target or "rectangle does not follow the mouse ... --hover" within 8 tries (never negative pixels). `embark.py scan 9,7
--hover` ends with a row `(hover read, no rectangle placed)` whose record has `tiles.n` 16; compare two panels with the
hovered tiles by eye (if they are one tile off, set `hover_k` in ui.json).
