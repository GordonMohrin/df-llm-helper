# BUG-257 Farms build_lost 'missing p' re-dug on the same stone site for 8 seasons
Status: fixed (offline, live-untested)
Severity: high (G4: no second farm for a year; Drillchamber farms BLOCKED:build_lost 34-43 % since summer, 8 retries)
Found: 2026-10-29, Run 15 Inkintense (c1a18745d4e25dac02, c1a1877db2410ee301 `soil 0/70`), Drillchamber (c1a187433a25b12d07; `bp sites farms --fresh` only `soil 0/70 plot tiles`), fix6-food-drink
Module: `dfpilot/bp/sites.py` (`_rooms` farms ranking), `lua/dfllm/runner.lua` (`retry_step`), `lua/dfllm/economy.lua` (`food_plan`)

## Actual
sites.py counted soil only as a +10 score per tile, so a stone site (`soil 0/70`) was a farms site; quickfort builds farm plots
only on soil or mud and skipped every `p` (`quickfort skipped ... 7 invalid`), the project went build_lost and the runner re-dug
the same anchor 8 times (one season apart). Once lost, economy asked for no farms at all (BUG-058).

## Fix
sites.py: with the soil known (the snapshot's soil marks) a farms candidate needs soil under at least half its plot tiles,
else it is refused (no site, rather than a doomed project); without any soil mark the soil stays unknown (plan check warns).
runner: a farms project's retries are spent at its first build_lost (kern.log `farms build_lost: plots need soil or mud, a
re-dig brings none: lost for good`). economy: each lost farms project is followed by one farms request (follow ranks the sites
anew, so the stone site is out), then the BUG-058 stop holds until bp.cancel.

## Tests
`tests/bp/test_sites_farms_soil.py`, `tests/lua/test_runner_farms_lost.lua`, `tests/lua/test_economy_food.lua`
`BUG-058/BUG-257` (fail on 2b9c009).

## Live check
`dfllm bp sites farms --fresh` in Drillchamber lists no `soil 0/70` site (or none at all: tell Gordon, a surface farm on soil
or irrigation is his call); the next farms build_lost logs `lost for good` once, kern.log `farms requested once at another site`
and a new farms project on a soil site.
