# BUG-143 Kernel texts print decimals with the locale's comma: '1,0 days', '10,0 days'
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: low (noise; a reader or a parser takes '1,0' for a list)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/reflex.lua, lua/dfllm/kern.lua, new lua/dfllm/util/num.lua

## Actual
DECISION_NEEDED #32428 `has held the BREACH for 1,0 days`; intruder_sortie `for 4,8 days`; kern.log `cleared after 10,0 days in SIEGE`.
In DF's Lua `string.format('%.1f', 4.8)` gives `4,8` with `os.setlocale()` = `German_Germany.utf8`.

## Cause
DF/DFHack runs with LC_NUMERIC of the player's locale; Lua's `%.Nf`, `tostring(float)` and float concatenation use its decimal point.
JSON is unaffected (`util/json.lua` writes integers only).

## Fix
`util/num.lua` `dec(x, n)` formats with integer math and always writes `.`; reflex (offer, kill_lone_intruder, the release log) and kern's
cadence line use it. `os.setlocale` is not called (process-wide, it would change DF). `tests/test_live_siege_i3.py` fails on any
`%.Nf`/`%g`/`%e` format in `lua/dfllm`.

## Tests
`tests/lua/test_bug143_145_reflex.lua` (the helper and the reflex texts under `German_Germany.utf8`; fail on dec5132), the source rule in
`tests/test_live_siege_i3.py`.
