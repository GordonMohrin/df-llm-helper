# Known lint findings in the bundled Lua scripts (`python -m df_llm_helper lint`)

These findings are documented and intentionally not "fixed". A new, undocumented finding makes the test
`test_bundled_lua_scripts_linted_without_crash` fail and must be assessed here (file + rule; line numbers may move).

| File:line rule | Assessment |
|---|---|
| arbeit.lua:243 L10 | Warning: shape of tiles that already carry a dig job (designated by the player route); no hidden check needed |
| bauprog.lua:83 L10 | Warning: reads tiles for its own planning (grid/build/mood slots); verify only revealed tiles are read |
| config.lua:77 L10 | Warning: finds the surface z of the map centre for the camera (no tile information is reported) |
| config.lua:237 L10 | Warning: "is this tile a construction" test for configured lock boxes (player-built tiles) |
| erzdig.lua:13 L10 | Warning: shape helper; the caller checks `d.hidden` before designating (header: only hidden=false tiles) |
| gesund.lua:200 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| kohle.lua:12 L10 | Warning: walkability helper; the caller checks `d.hidden` before designating |
| mood.lua:82 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| mood.lua:213 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| probe.lua:32 L10 | Warning: documented in its header: reads only the shape of hidden neighbour tiles (safe/unsafe, no material) |
| raster.lua:128 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| pilot_caravan.lua:21 L07 | Intended: send stuck merchants home (`flags1.left`); df-llm-helper only calls it with an exception-register entry FP09 (player consent) |

Since BUG-318 the L10 check looks for a `hidden` check within 30 lines before / 10 lines after the tile read instead of
anywhere in the file, which added the helper functions above. The table must match the real output in both
directions (the test also fails for a documented finding that no longer exists).
