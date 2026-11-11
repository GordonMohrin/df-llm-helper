# BUG-726 embark rank/scan: an active sweep blocked the next one and showed the old result, a map-edge box failed in world.goto, 'brook=none seen' hid how few tiles were read
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10/11, Run 16d i4 Pagedsculpture (a `--budget` end left the sweep running; `rank --box 0,17,...` and a box at y=0 failed 'world.goto: not zoomed in' x8; hover said 'brook EDGE ONLY 4 tiles', the rectangle scans 'brook=none seen' for 5,6 and 6,6; E21)
Module: `tools/embark/embark.py` (`start_run`, `spec_box_text`, `wait`, `brook_text`), `tools/embark/steps.lua` (`S.goto_world`), `tools/embark/embark.lua` (`W.world_size`)

## Root cause
1. `embark.lua start` refuses a second run ('run X is active; use stop'); dfhack-run answered rc 0, the driver waited for a run that never started and, at the timeout, returned status.json of the OLD run.
2. `world.goto` set the camera to the target minus the learnt offset; at the map edge that is below 0 (or past the last tile), the click at the window centre hit no region ('not zoomed in' on every try).
3. A rectangle scan reads the panel of ONE hovered tile, a hover row up to 16; 'none seen' did not say so.

## Fix
1. `start_run`: on 'is active' names the old run with its box, stops it, waits up to 20 s and starts the new run once, else SystemExit with the reason. `wait` returns None at the timeout when status.json is another run's. `rank` prints its box.
2. The camera stays inside the map (`W.world_size`); the tiles the clamp took away are a click shift of one grid cell per tile from the window centre. The learnt offset excludes the shift. Before an offset is known an edge tile that did not zoom tries the click aside (-1, +1, -2, +2).
3. `brook_text`: ' brook=none seen on N of 16 tiles (a rectangle scan reads one hovered tile, `scan --hover` reads all 16 ...)' when fewer than 16 were read.

## Tests
`tests/test_bug726_embark_run.py` (6), `tests/lua/test_bug726_embark_edge.lua` (4: x=0, y=0, first tile at the edge, last column; the fake DF clamps the camera, 3 of the 4 fail on the old code), `tests/test_embark.py` (`wait` of another run).

## Live check
A second `rank` while one runs stops the first, names its box and reads the new box; `rank --box 0,17,...` reaches the x=0 tiles. Open: the shift assumes one grid cell per world tile on the world map (live-untested).
