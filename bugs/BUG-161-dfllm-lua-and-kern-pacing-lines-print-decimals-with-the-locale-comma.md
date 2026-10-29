# BUG-161 `dfhack-run dfllm status` and the kernel's pacing lines print decimals with the locale's comma
Status: fixed (offline, live-untested)
Severity: low (text only: `load x8,89`; a float pacing share would read `2,5 ms/s` in kern.log)
Found: 2026-10-29, live test round 2, instance i3 (Trussroads y722), item NEW5, confirmed by the skeptic
Module: `lua/dfllm.lua`, `lua/dfllm/kern.lua` (`note_paced`, `note_floor`), `lua/dfllm/util/num.lua` (`M.num`)

## Actual
DF runs with LC_NUMERIC = the player's locale (German_Germany.utf8: `tostring(4.8)` = `4,8`). BUG-143's source rule covered only `%.Nf/%g/%e`
inside `lua/dfllm/`. `lua/dfllm.lua:69` used `string.format('load x%.2f', s.load.f_pct / 100)` (live: `load x8,89`); dfllm.lua and kern.lua
printed `tostring(share)` of the pacing share, a float when a config share is one.

## Fix
`NUM.dec(f_pct / 100, 2)` for the load; `util/num.num(x, n)` (an integral value without a point, else `dec` without trailing zeros) for the
shares. The pytest rule now covers every file under `lua/` (dfllm.lua, dfllm-hud.lua included) and also flags `tostring(<division>)`,
`tostring(...share)` and a division concatenated with `..`.

## Tests
`tests/test_bug159_161_live2.py::test_no_lua_file_prints_a_decimal_with_the_locale` (fails on main b805745: 4 hits) and
`::test_the_rule_catches_the_live_leaks`; `tests/lua/test_bug161_num.lua` (num under the German locale).

## Live check
`dfhack-run dfllm status` on a German-locale DF: `fort size: N units, M items, load x8.89`; paced modules read `share N ms/s`.
