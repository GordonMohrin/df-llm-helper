# BUG-868 Texts that misled the players: halt (drink), ladder terrain block, why-brew scan
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17: i2 growth halt '(drink)' beside 249 drink days in the fort; i1/i4 the ladder kept `plan propose (fortcore vorn)` although `bp sites fortcore` said no site; i2 why-brew `plant (DRINK_MAT) x1: 0 match` beside 'items:plants 936 free, 923 in a container'.
Module: `lua/dfllm/readiness.lua` (status line `growth N (...)`), `lua/dfllm/jobwhy.lua` (`J.input_text`), `dfpilot/cli.py` (`bp sites` log), `dfpilot/leiter.py` (`_state_blocked`, `TERRAIN`)

## Root cause
The halt shows the key only; the key `drink` counts the drink INSIDE the core. The `bp sites` reply with `free 0` logged only 'ranked N free 0' (the tool's reason was printed, not logged) and the block held just `blocked_hours` (6 h) although terrain does not change in hours. The brew scan's plain 'N match' hid that the census holds the plants (in containers, DF's normal case).

## Fix
The status line names `drink in core 12 d < 120 d`; `bp sites` logs `no <tpl> site: <reason>` to cli.log and the ladder prints it as BLOCKIERT; a terrain reason (aquifer, water, damp, magma, cavern) holds four times as long; the why-brew line says `0 match by the scan, the census holds N usable (plants inside containers count as input)`.

## Tests
`tests/lua/test_bug864_870_ruest.lua` (drink need text, brew input text), `tests/test_bug868_leiter_terrain.py`.

## Live-Erwartung
i2 status line `growth N (drink in core X d < Y d)`; i1/i4 BLOCKIERT with the tool's words after a `bp sites fortcore` and the next candidate in NAECHST; why-brew names the census plants. NOT done: the GATE_FAIL-in-PEACE wake of i3 (`B1 not up after 269075 ticks ... blocked: citizen walking onto it`): the cause is not confirmed from data (a kernel want in PEACE is reverted by the peace rules, only a player `lever up` keeps it; a branch that suppressed it could not be shown to fire in the fake world), so gate.lua is unchanged.
