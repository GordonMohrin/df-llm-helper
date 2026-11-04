# BUG-332 `dfllm save` says QUICKSAVE_FAILED: it looks for the save in %APPDATA% while DF saves portably to <DF>/save
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15 (i2 Guildcleans 'autosave 1' 20:21, i4 Drillchamber 'autosave 2' 20:24)
Module: `dfpilot/supervise.py` (default_env, saves_root), `lua/dfllm/kern.lua` (boot, save_root)

## Actual
i2 cli.log 1793301867: `quicksave ... QUICKSAVE_FAILED no fortress save folder newer than the call after 183 s (dfhack-run
printed nothing; DF started no save: save/current stayed empty) with the game paused; the newest save is 'a-run15-guildcleans'
fr...`, while DF had written `autosave 1` to `E:/DF-test2/save`. All four installs run in portable mode
(`<DF>/prefs/portable.txt`, saves in `<DF>/save`); 'a-run15-guildcleans' is a folder in `%APPDATA%/Bay 12 Games/Dwarf
Fortress/save`. A verified save never counted, `follow` woke QUICKSAVE_FAILED (class A) after every save.

Root cause: `dfpilot/supervise.py:107-108` (9b6f614) `default_env`: the save folder was `$DFLLM_SAVES` or always
`%APPDATA%/Bay 12 Games/Dwarf Fortress/save`; DF's portable mode was never looked at. The same folder feeds supervise (backups,
crash reload: the newest save), `dfllm load`/`loadnow` and `follow`'s QUICKSAVE settle.

## Fix
- `supervise.saves_root(df, runtime)` -> (folder, source): `$DFLLM_SAVES`; else `<runtime>/SAVEDIR` when that folder exists
  (a relative one is below `<df>`); else `<df>/save` when `<df>/prefs/portable.txt` exists; else %APPDATA%. `default_env` uses it.
- Kernel: `kern.save_root()` = the parent of `dfhack.getSavePath()` (the loaded save's folder), else
  `dfhack.filesystem.getBaseDir() .. 'save'`; boot writes it to `<runtime>/SAVEDIR` beside ACTIVE (DF's own answer, also
  for a non-portable install whose pref dir is not %APPDATA%).
- `QUICKSAVE_FAILED:` names the folder it looked at.

## Tests
`tests/test_bug332_save_root.py` (5; portable, SAVEDIR, default_env fail on 9b6f614), `tests/lua/test_bug332_save_root.lua` (2).

## Live check
After a kernel reload: `<DF>/dfllm-runtime/SAVEDIR` names `<DF>/save` (e.g. `E:/DF-test2/save`). `dfllm save --dry-run` prints
`... for a new folder in E:\DF-test2\save`; the next `dfllm save` is `quicksave ok: ... written N s after the call`.
Uncertain: whether DFHack 53.16's `getSavePath()` is absolute (a relative one is read below `<df>`); before the reload the
portable rule alone gives the same folder.
