# BUG-202 The plan's and season's order libraries were imported at P0 with 7 dwarves, past the stage gates (80-90 orders)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F6; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (`T.imports`, `M.lib_ready`)

## Actual
`T.imports` checked `M.stage_ready` for the config stages only; `K.plan.orders.import` and the season imports were added with no gate, so
basic (cit >= 10 or migrants), rockstock (Masons + stone) and furnace (a furnace) came at once: 'orders 80 stuck 57'.

## Fix
- A plan or season library that is the library of a config stage (`economy.stages`) waits for that stage's gate (`M.lib_ready`); any other
  library is imported as before. kern.log names a held library once per boot. (The propose side, libraries from later phases, is plan.py.)

## Tests
`tests/lua/test_economy.lua` (BUG-202 and the plan/season import test). Each fails on bd27973.

## Live check
A P0 fort of 7 with a plan importing library/basic: kern.log `orders library/basic of the plan held until its stage is ready`; the import
comes with migrants or 10 citizens.
