# Known lint findings in the bundled Lua scripts (`python -m df_llm_helper lint`)

These findings are documented and intentionally not "fixed". A new, undocumented finding makes the test
`test_bundled_lua_scripts_linted_without_crash` fail and must be assessed here (file + rule; line numbers may move).

| File:line rule | Assessment |
|---|---|
| arbeit.lua:243 L10 | Warning: shape of tiles that already carry a dig job (designated by the player route); no hidden check needed |
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

Resolved: `bauprog.lua` L10 (BUG-418: `shape_at` returns nothing for undiscovered tiles, so `waende_offen` no longer
counts walls in unrevealed rock). `lint lua/claude lua/` reports each file once (paths are de-duplicated).
Open decision (BUG-418): `pilot_caravan.lua` L07 stays an error until the player's FP09 consent is in
`data/exceptions.jsonl`; `claude/dig` judges undiscovered tiles by their real shape (designate blindly or skip them? its header now says so).

## Not reported (BUG-319, decided)

- `deathcause` and `gaydar` are no cheats: they only read and show what the game UI also shows (L25 and the
  runtime rule FP07 no longer list them).
- `createitem` in pure message text is no command: a line that only passes text to `print`, `qerror`,
  `dfhack.printerr`, `util.emit`, `say`, `log`, ... and executes nothing, and comments. As a command it stays an L01
  error: a `run_command`/`run_script` argument, a bare command line, a string that may be executed (any other string
  literal, `os.execute`, `io.popen`, `load`).
