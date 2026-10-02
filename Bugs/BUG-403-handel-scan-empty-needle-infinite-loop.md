# BUG-403: `claude/handel scan ""` (empty search text) loops forever in the game's main thread

- **Status:** open (found by code reading, **deliberately NOT executed** - it would hang the running game)
- **Severity:** S1 (hangs Dwarf Fortress; no timeout inside DFHack for a Lua loop)
- **Area:** `lua/claude/handel.lua:108-123` (`find_text`), reached from `cmd.scan` (`handel.lua:776-782`) and from `cmd.open`/`cmd.accept` (those pass non-empty constants, so only `scan` is exposed)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), static analysis

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/handel scan ""        # NOT RUN
```
(`claude/handel scan` without text is handled: `{ "abort": "scan <text>", "ok": false }`, verified live.)

## Expected
`{"ok":false,"abort":"scan <text>"}` or an empty `hits` list.

## Actual (predicted from the source)
```lua
local function find_text(needle, rows)
  ...
  local low = needle:lower()            -- '' for an empty needle
  for y, row in pairs(rows) do
    local init = 1
    while true do
      local s, e = rl:find(low, init, true)   -- ("abc"):find("", 1, true) -> 1, 0
      if not s then break end
      res[#res + 1] = { ... }
      init = e + 1                            -- = 0 + 1 = 1: init never advances
    end
  end
```
`string.find(row, "", init, true)` returns `init, init-1` for every `init <= #row + 1`, so `init = e + 1` stays at `init`; `s` is never nil -> endless loop that also grows `res` without bound (memory). `cmd.scan` only tests `if not needle`, and `""` is truthy in Lua. Whether `dfhack-run.exe` forwards an empty argument as `''` is the only unknown; PowerShell/cmd quoting (`""`) normally does.

## Evidence
none needed (not executed on purpose). Verified live only: the guard for a *missing* argument works (`claude/handel scan` -> `{"abort":"scan <text>","ok":false}`) and a normal needle returns `hits: []` in 0.1-0.3 s.

## Analysis (reporter's hypothesis)
Missing `needle == ''` check and a non-advancing step for zero-length matches. `df_llm_helper` calls `claude/handel scan <text>` (client.py `is_write` marks it read-only, `register_read`), so an LLM-generated empty text would freeze the game.

## Suggested fix (optional)
`if not needle or needle == '' then return fail('scan <text>') end` in `cmd.scan`, and `init = math.max(e, init) + 1` in `find_text` as defence.

## Info needed
- Cloud session: a mock test is possible without the game (`("abc"):find("", 1, true)` in a real Lua 5.3/5.4 returns `1 0`).
- Player: **do not** test this on the live game. If you want to confirm, do it on a throw-away fort after saving.
