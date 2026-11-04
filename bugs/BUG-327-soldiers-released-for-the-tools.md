# BUG-327 the tools-first rule releases every melee soldier, the squads are never refilled in PEACE
Status: fixed (offline, live-untested)
Severity: critical (the fort stands without soldiers: mil 0 at pop 53, G9/G18 red)
Found: 2026-10-29, Run 15c Inkintense (i1, site97, y373-y378), live dfpilot of that day, kern.log + status
Module: lua/dfllm/military.lua:651 (M.targets, the tools-first rule), :3561 (M.step: `release(K, 'tools', 'melee')`)

Expected / Actual:
Soldiers stay soldiers when the fort is short of axes or picks; a squad below its target is filled again. Actual: with
fewer than TOOLS_MIN (3) axes or picks in the whole fort, M.targets dropped the melee squads from the wanted list (at
phase < P5 only squad A is wanted, so the total became 0 with `zero = 'tools'`) and every PEACE upkeep released every
melee soldier (uniforms cleared, squad_remove). A SIEGE/BREACH (hold_floor, HOLD_MIN) or a drill filled squad A again, the
next PEACE upkeep released them again; the militia squad B (melee) was emptied and its rotation found 0 members window
after window. Nothing but a kern.log warn line said so.

Evidence (r15c-inkintense-site97/kern.log, read-only):
```
1269  151275349 warn military: 2 soldiers released (tools): uniforms cleared, the tools go back to the civilians
1785  151748511 warn military: 6 soldiers released (tools): ...
1992  151876957 warn military: 6 soldiers released (tools): ...
2085  151884757 warn military: squad A: 1 positions without a weapon (no spare weapon; 1 axes and 3 picks stay with the civilians)
2172  151900359 warn military: 5 soldiers released (tools): ...
2650  152144394 warn military: 6 soldiers released (tools): ...
2993  152465909 warn military: 8 soldiers released (tools): ...
3240  152417013 warn military: 6 soldiers released (tools): ...
2185  151907559 info military: militia squad B on duty (months 9-11): 0 members, 50 citizens
```
The fort held 1 axe and 3 picks (line 2085): census w_axe 1 < TOOLS_MIN. runs/run-15c-inkintense/FR-BUGS.md:355: "8
soldiers released (tools)" -> status `mil 0sq 0sol cv 0` (13 soldiers before), squad B 0 members, never refilled.

Cause: live L6 (Laborkings) added the tools-first rule (no melee soldiers below TOOLS_MIN axes or picks) before the weapon
guard existed. The later guard (weapon_guard / tool_excess / release_tools, BUG-023) already keeps the axes and picks with
the civilians (explicit non-tool weapon specs, no pick spec at all, reserved tools unassigned), so the rule only emptied
the squads. Why the refill did not help: fill() refills to `per[key]`, and the rule set the melee targets to 0 in PEACE;
only the siege floor (HOLD_MIN) refilled squad A, and the next PEACE upkeep released it again.

Fix: M.targets no longer lowers any target for the tools (`short` stays as a report); M.step releases only for
`zero = 'phase'`. The weapon guard keeps the tools with the civilians; a position without a spare weapon trains with a
wooden one (G18). Every leave without a swap (release; fill's one member over target + KEEP_EXTRA) emits SOLDIERS_RELEASED
(B, military: n, why, squads), keeps state `mil.rel` {n, why, t, sq} and shows the status line `soldiers released: 8
(phase) from AB 2.1 d ago` (core part within a month, detail after).

Tests: tests/lua/test_military.lua (BUG-327 x2, the phase test checks the event and mil.rel), tests/lua/test_military_refill.lua
(siege with 1 axe: B back to its target; after the siege the squads stay in PEACE), tests/test_bug327_soldiers_released.py
(schema, contract, status line). All BUG-327 Lua tests fail on 9b6f614.

Open: the economy orders picks (plan_picks) but no axes for the woodcutters; a fort with 1 axe now keeps its soldiers,
yet still needs a forge order or a caravan for axes. Whether DF makes a soldier drop an axe he already carries when his
spec changes to another weapon is live-unproven (release_tools only unassigns tools nobody carries).
Related: live L6/L7, BUG-023, BUG-050, BUG-076, FR-79, FR-100 (G18), Run 11 siege 3 (HOLD_MIN)
