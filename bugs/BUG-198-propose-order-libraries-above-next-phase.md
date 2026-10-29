# BUG-198 `plan propose` imports order libraries of every phase up to the target (P3 libraries at P0)
Status: fixed (offline, live-untested; the kernel half in economy.lua is a separate package)
Severity: medium (80-90 manager orders at P0 with 7 dwarves; project piece orders starve behind them)
Found: 2026-10-29, live test round 3, Earthboat (finding F6, plan.py part, skeptic re-check)
Module: `dfpilot/plan.py` (`propose`)

## Actual
The deliver loop added every `orders` library of the phases cur..target (target P5: library/basic, rockstock, furnace from P3).
T.imports in economy.lua imports plan libraries at once, without the stage gates.

## Fix
propose takes a library only from phases up to the one after the current phase (cur + 1). The kernel gate (economy.lua
T.imports, T.stale's made-again order) is not part of this fix.

## Tests
`tests/test_bug195_198_plan_place.py::test_order_libraries_come_from_the_next_phase_at_most`, fails on bd27973.

## Live check
A fort at P0: `python -m dfpilot plan propose <scratch>/p.json`: the summary's `orders` lists only libraries of P0 and P1.
