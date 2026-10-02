# Known lint findings in the bundled Lua scripts (`python -m df_llm_helper lint`)

These findings are documented and intentionally not "fixed". A new, undocumented finding makes the test
`test_bundled_lua_scripts_linted_without_crash` fail and must be assessed here (file + rule; line numbers may move).

| File:line rule | Assessment |
|---|---|
| bauprog.lua:83 L10 | Warning: reads tiles for its own planning (grid/build/mood slots); verify only revealed tiles are read |
| gesund.lua:200 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| mil.lua:297 L08 | False positive: target of a squad station order (squad_order_movest), not a teleport |
| mood.lua:82 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| mood.lua:213 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| raster.lua:106 L10 | Warning: reads tiles for its own planning; verify only revealed tiles are read |
| pilot_caravan.lua:21 L07 | Intended: send stuck merchants home (`flags1.left`); df-llm-helper only calls it with an exception-register entry FP09 (player consent) |
