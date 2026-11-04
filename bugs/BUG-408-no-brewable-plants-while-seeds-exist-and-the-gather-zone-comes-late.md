# BUG-408 'no brewable plants' while 50 seeds exist: nobody plants them, the gather zone comes at 60 drink days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Bachwald R3, y373, `runs/run-16a/FR-BUGS.md`), main 503bb8b
Module: `lua/dfllm/economy.lua`

## Actual
i1: 'no brewable plants' beside 50 seeds, no farm plot (farms surface=1 refused, BUG-407), drink 0 from y373, 13 dead of thirst.

## Root cause
(1) With no plot at all nothing asked for one: the farms requests belong to the food path only (BUG-406 has the same gap). (2) The wild
brewable plants are gathered by the zone the runner draws for `stock.bshort`, and `M.drink_low` set `bshort` only below
`gather.drink_d` (60) drink days, i.e. when the stills were nearly idle already (economy.lua:4882).

## Fix
- BUG-406's request also covers 'no plot at all': brewable seeds in stock and no plot of their kind (0 plots) -> `PROJECT_REQUEST farms
  why=drink|drink_surface` (see BUG-406).
- `gather.drink_early` (120, config/baseline.json, `fairplay.py` limit 0-400): with no brewable plant at all (census brew_p + brew_g = 0)
  `bshort` is set below 120 drink days; `M.gather_low` stays on while `bshort` (its members leave at the old line only when `bshort` is off).

## Tests
tests/lua/test_bug406_brew_fit.lua ('BUG-408' x2). Fail on 503bb8b.

## Live check
i1-like: no brewable plants, drink 100 d: `stock.bshort 1`, the gather zone drawn, gatherers added ('drink_low'); brewable seeds and no plot: PROJECT_REQUEST farms.
