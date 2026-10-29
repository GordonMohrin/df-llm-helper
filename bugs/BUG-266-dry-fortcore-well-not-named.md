# BUG-266 The dry fortcore well is not named: HOSPITAL_DRY does not say that only buckets fill its sump, nor from where
Status: fixed (offline, live-untested)
Severity: medium (the AI player cannot tell why the fort's only well is dry)
Found: 2026-10-29, Run 15 Drillchamber y372 winter, fix6-water
Module: `lua/dfllm/water.lua` (`M.dry_well`, `M.dry_causes`, `emit_gate`), `dfpilot/bp/fortcore.py` (comment of the stage-1 well)

## Actual
status y372 win d46 `Kern+ refused: drink 0<17 (1 well, none wet)`; `inspect water_sources`: well 17718 at 91,70,139 not accepted,
the brook body at 141,67,143 reach 0. fortcore stage 1 builds its well and pond hole over a 2-tile sump with no water check: only bucket
carriers fill it, from water they reach. HOSPITAL_DRY said only "no wet well".

## Fix
While the hospital is dry or no water is accepted, the first built, dry well outside a cistern room is named in HOSPITAL_DRY's cause:
`dry well N at x,y,z (0/7): only buckets fill its sump; fill source: the water at x,y,z (bank x,y,z)` (the scan's nearest body with a
reachable bank) or `no water a carrier reaches to fill it`; the first alarm that waits for the scan gets the scan's fill source.
fortcore.py documents that the stage-1 well has no water check and is no source by itself (BUG-263).

## Tests
`tests/lua/test_bug262_266_water.lua` `BUG-266 ...` (fails on 2b9c009).

## Live check
Drillchamber-like fort: HOSPITAL_DRY `(dry well 17718 at 91,70,139 (0/7): only buckets fill its sump; ...)`.
