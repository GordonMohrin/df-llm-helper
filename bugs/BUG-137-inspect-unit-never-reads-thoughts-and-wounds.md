# BUG-137 `inspect what=unit`: thoughts and wounds never read for a living unit, mood "None", the CLI id refused, view replies in CP437
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: medium (the sheet reader answered half of what it promises)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier
Module: `lua/dfllm/curse.lua` (`thoughts_of`, `wounds_of`, `inspect_unit`, `LINKS`), `dfpilot/schema.py` (`inspect` key),
`lua/dfllm/viewlib.lua`

## Actual
`unread:["thoughts","wounds"]` on 39750, 41696, 42129, 41657, 39052. `cmd inspect what=unit key=39052` ->
`refused (not sent): $.args.key: expected str, got int`. Mood `None` for mood -1; the line of a dead unit did not say DEAD; a late spouse
was not listed. `view` replied `camera on Urvad K�bukarban`.

## Causes
`for i = #list, 1, -1 do list[i]` on a 0-based DF vector (index out of bounds, the whole read failed); `wd.bleeding` does not exist
(`unit_wound.parts[j].bleeding` does); `df.mood_type[-1]` = `None`; `LINKS` lacked `DECEASED_SPOUSE`; the schema `key` was `Str` while
`cmd.parse_kv` turns digits into an int; `viewlib.unit` used `getReadableName` without `df2utf`.

## Fix
Thoughts `for i = #list - 1, 0, -1` (an emotion without a thought names its `df.emotion_type`); a wound bleeds when one of its parts
does; mood only for `u.mood >= 0`; `, DEAD` in the line of a dead unit; `DECEASED_SPOUSE` = `late spouse`; schema
`key: AnyOf(NAT, Str(maxbytes=80))` (the Lua side already takes a number); `viewlib` converts the name with `dfhack.df2utf`.

## Tests
`tests/lua/test_curse_live.lua` (BUG-137 x2), `tests/test_curse_live.py`; `tests/lua/test_curse.lua` reads the wounds in parts.
