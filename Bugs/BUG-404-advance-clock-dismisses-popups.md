# BUG-404: `claude/advance clock` (documented and classified as read-only) deletes the game's message popups

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S2
- **Area:** `lua/claude/advance.lua:12-22`; classification `df_llm_helper/client.py:62` (`_READ_EXACT` contains `"claude/advance clock"`), COMPANION.md ("`advance clock` must contain `"paused"`", header of advance.lua: "`claude/advance clock` - only report time/pause status")
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), static analysis

## Command / steps
```
dfhack-run.exe claude/advance clock       # NOT RUN
```

## Expected
Only reports `paused`, `date`, `timer_active`; changes nothing.

## Actual (from the source)
```lua
local function dismiss_popups() ... while #p > 0 do local x = p[#p - 1]; p:erase(#p - 1); x:delete() end ... end
local dismissed = dismiss_popups()        -- line 22: runs for EVERY argument, before 'clock' / 'run' / a number / an error
```
`world.status.popups` (the "Migrants have arrived", siege, mood, caravan announcement windows) is emptied on every call, including the pure read `clock`. The popup text is lost for the human player (and for any code that reads it later); only a `popups_dismissed` count is returned. The same happens for an invalid argument (`claude/advance foo` -> popups gone, then the error). `df_llm_helper.client.is_write("claude/advance clock")` returns False, so the fair-play/maintenance layer treats it as free to call every few seconds.

## Evidence
none needed (code reading). For comparison, the watchdog clears popups every 600 ticks by design (`watchdog.lua:399-405`), so the effect is hidden when the watchdog runs, but not when it does not.

## Analysis (reporter's hypothesis)
`dismiss_popups()` was meant for the `run` / `<ticks>` paths (the game halts on popups). It should only be called there.

## Suggested fix (optional)
Move `local dismissed = dismiss_popups()` below the `clock` branch (or call it only when `arg == 'run'` or a tick number is given).

## Info needed
- Player: is it intended that a status poll silently confirms announcements? If yes, drop `claude/advance clock` from `_READ_EXACT`.
- Player (needs running time, see BUG-405): none for this bug.

## Fix
Popups are dismissed only by `run` and `<ticks>`; `clock`, `0` and invalid arguments change nothing (mock test). `claude/advance clock` stays a read in `client.is_write`.
