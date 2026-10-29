# BUG-245 embark newgame picks the first of several same-named worlds
Status: fixed (offline, live-untested)
Severity: medium (the new fort lands in the wrong world folder, e.g. region2 AppData instead of region1 portable)
Found: 2026-10-29, Run 15c Inkintense (i1) and Run 15d Drillchamber (i4), y372
Module: `tools/embark/steps.lua` (`S.newgame`, `S.folder_rows`, `S.pick_folder`, `S.region_check`),
`tools/embark/embark.lua` (`source().title.regions`), `tools/embark/embark.py` (`newgame --world-folder`)

## Actual
"Start new game in existing world" listed three `World: Zilirr?th` (region2 AppData, region1 portable, region1 AppData).
`title.world` tapped the world name, i.e. the topmost row (region2). Both players clicked "Portable Folder: region1" by hand
(click4.lua) and checked `dfhack.getSavePath()` afterwards. `--world-folder` existed only for `load` (BUG-230).

## Fix
`newgame --world-folder F [--portable | --appdata]`: `title.world` clicks the one row that shows "folder:" followed by F as a
whole word ("Portable Folder: F" = portable, "Folder: F" = AppData); several rows of F without a kind, or none, fail and name
what was seen. When DFHack shows `viewscreen_titlest.region_choice` (read only: `full_path`, `is_portable`) the folder of that
kind must be in it. The clicked row goes into the result (`world row clicked: ...`). Without `--world-folder` nothing changes.

## Tests
`tests/lua/test_embark_fix6.lua` `BUG-245 ...` (three same-named worlds: portable, appdata, ambiguous, missing; folder
rows and region_choice); `tests/test_bug245_250_embark_tools.py::test_bug245_...`. All fail on 6dc0f19.

## Live check
At "Start new game in existing world" with same-named worlds: `python tools/embark/embark.py newgame --world-folder region1
--portable` prints `world row clicked: "Portable Folder: region1"`; after the world map shows, `dfhack.getSavePath()` (or the
fort's save folder after the embark) lies under `<DF>/save/region1`. If the run fails with "no row shows", the folder row text
differs: read `embark.py screen` there.
