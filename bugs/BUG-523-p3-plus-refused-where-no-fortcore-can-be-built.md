# BUG-523 P3+ plans are refused for O1 and B2 where no fortcore can ever be built, the fort is capped at P2 for years
Status: fixed (offline, live-untested)
Severity: high (a fort with food and drink for 800 days sat on P2 and a pop ceiling of 29 after the siege)
Found: 2026-11-06, Run 16a i1 Basementflew y408-y411 (`runs/run-16a/FR-BUGS.md` "BUG plan check y408"; aquifer z114-z127 with heavy layers z116/z120/z123, stone 0, `bp sites fortcore aquifer=pass` 0 sites; read only)
Module: `dfpilot/plan.py` (`stage3_gate`, `no_core_why`, `no_core_route`)

## Actual
propose drew P5, `plan check` refused every P3+ plan with `stage 3: phase_target P5 (P3+) needs O1, B2 and the refuge ... add fortcore stage 3`; only P2 could be applied (y408-y411). Fortcore stage 3 builds O1 and B2 and cannot be dug in this world, so the demand could never be met.

## Root cause
`stage3_gate` (plan.py) exempted only the surface core (`surface.have` / `surface_need`, off by default since BUG-413). A fort whose core cannot be built any other way (`surface.need`, the aquifer route `surface.aq.ok` false, no fortcore applied) fell through to the error. `no_core_route` (BUG-415) knew the reason, but only for a fort without a refuge burrow; Basementflew has the surface Tiefe+ of the aquifer shaft, so neither propose's cap nor the gate used it.

## Fix
`no_core_why(fort)` is the one reason (no sites ranking, no aquifer route / no surface core site); `no_core_route` calls it. `stage3_gate` no longer errors when it holds: it warns once, naming the cause and what P3+ requires instead: a separated refuge with beds for `refuge.bed_pct` of the citizens (refuge_gate, unchanged), the seal on every way in (`seal at=last`) and, from P5, the drill; O1 and B2 are asked for again as soon as a core is placed (the gate returns by itself when `surface.need` ends). A fort that can still build a core, or has stage 3 under way / built, is judged as before. gate.lua, the bridges and the drill are untouched.

## Tests
`tests/test_bug523_527_f33.py` (3 for the gate: no error + the warning text, the old errors where a core can be built, `no_core_why` is the one reason).

## Live check
On a fort where `bp sites fortcore aquifer=pass` finds nothing: `plan propose` then `plan check` of a P3+ plan prints a `stage 3: ... no fortcore can be built (...)` WARNING instead of an ERROR and the plan applies.
Open: refuge_gate still needs a separated refuge with beds (its own errors remain); the readiness levels that count O1 and B2 stay red without a core (R0 no_outer/no_inner); the surface core (plan.surface_core true) is the other way out and unchanged.
