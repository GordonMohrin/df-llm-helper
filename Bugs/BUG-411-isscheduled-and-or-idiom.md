# BUG-411: `x and f() or fallback` idiom turns "job not running" (`false`) into `'unbekannt'` (kohle) / a missing key (raster) / `cmd=='start'` (watchdog)

- **Status:** open
- **Severity:** S3
- **Area:** `lua/claude/kohle.lua:71`, `lua/claude/raster.lua:240`, `lua/claude/watchdog.lua:420`, `lua/claude/ueberwacher.lua:113`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), `repeat-util` of this DFHack has `isScheduled` (checked: `hack/lua/repeat-util.lua:13`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/kohle status
./dfhack-run.exe claude/raster status
```

## Expected
`{"laeuft": false}` when the periodic job is not scheduled, `true` when it is.

## Actual
- `claude/kohle status` -> `{ "laeuft": "unbekannt" }` although `repeatUtil.isScheduled` exists. Cause (`kohle.lua:71`): `repeatUtil.isScheduled and repeatUtil.isScheduled(KEY) or 'unbekannt'` - when the call returns `false`, Lua's `a and b or c` falls through to `'unbekannt'`. Because the job is off the answer is always "unknown".
- `claude/raster status` -> no `laeuft` key at all (`raster.lua:240 ... or nil` drops the key for `false`); the Python side documents this workaround in `workload.py:171` ("the key is MISSING while the job is off").
- `watchdog.lua:420` `... or (cmd == 'start')` and `ueberwacher.lua:113` `(cmd == 'start') or isScheduled(KEY)` are correct today, but the pattern is fragile: `claude/watchdog stop` reports `running` from `isScheduled` (false) only because `cmd ~= 'start'`.

## Evidence
`Bugs/evidence/BUG-411/kohle_status.out.txt`, `raster_status.out.txt` (the latter shows the missing key).

## Suggested fix (optional)
`laeuft = repeatUtil.isScheduled(KEY)` (boolean), in raster/kohle/watchdog/ueberwacher alike; then delete the workaround in `workload.py:171`.

## Info needed
none.
