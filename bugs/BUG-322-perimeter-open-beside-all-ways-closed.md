# BUG-322 status says PERIMETER OPEN with N ways in beside "ways in: all with a door or bridge"
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15b (Earthboat, live, y385 spr, a siege of 35 goblins running)
Module: `lua/dfllm/readiness.lua` (evaluate, M.perim_now)

## Actual
`dfllm status` showed at once `PERIMETER OPEN 46 days: 2 ways in` (R0 open_perimeter) and `ways in: all with a door or bridge`;
`bp.place tpl=seal at=last` was refused `nothing to close (the last entrance check names no open way in)`. The state
(state.a.json / state.b.json, tick 93053 y385, mode SIEGE): `ready.open 0, ready.pd 47, ready.pw "2 ways in"`.

Root cause: `lua/dfllm/readiness.lua:529-536` (1d17c7e). The open-perimeter text `rt.pw` was computed in PEACE only; outside
PEACE `if not rt.pw then rt.pw = st.pw end` kept the text of the last PEACE evaluation for the whole SIEGE/ALERT, while
`rt.open` (the ways-in line of status and SIEGE_UNREADY) and `seal at=last` read the entrance check of now. Two readings of one fact.

## Fix
Outside PEACE the signal is still never started (a lockdown is no news) and lost bridges/levers keep their last answer, but its
ways in are the entrance check's count of now (`M.perim_now(st.pw, rt.open)` replaces the `N ways in` part). When nothing is left
open (no way in, no lost bridge or lever in the text) the signal ends (pd, phold cleared), as in PEACE. No check yet (`open` -1):
unchanged.

## Tests
`tests/lua/test_bug322_perimeter_one_source.lua` (2, both fail on 1d17c7e): a siege with 2 -> 1 -> 0 ways in (pw follows, then
pd nil and no open_perimeter), not started in a siege; `perim_now` keeps bridges/levers. `tests/lua/test_open_perimeter.lua`: the
reload test now closes in ALERT (old assertion: the days ran on in ALERT with every way closed).

## Live check
Earthboat after the kernel loads this code, still in SIEGE: `dfllm status` shows no `PERIMETER OPEN` line while `ways in: all with a
door or bridge`; `state ready.pw` agrees with `ready.open`. Uncertain: whether the 2 ways in of y383 were real until the siege
(seal at=last closed 4 gaps then); a later PEACE check that finds them again restarts the clock at 0 days.
