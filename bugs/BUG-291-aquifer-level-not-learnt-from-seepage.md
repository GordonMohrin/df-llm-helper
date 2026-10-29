# BUG-291 the aquifer level is not learnt from revealed seepage
Status: fixed (offline, live-untested)
Severity: high (Run 15 Inkintense: `bp sites cistern water=aquifer` -> 'no aquifer level known' while water >= 4/7 seeped into the
sealed pit on z130)
Found: 2026-10-29, Run 15 round 2 (Inkintense FR-BUGS)
Module: `lua/dfllm/water.lua` (scan_body, scan_done, M.aq_level), `lua/dfllm/runner.lua` (M.aq_seen)

## Actual
The manifest's `aquifer_levels` came only from damp reports of digs (runner Q.aq_level via aqshaft/observe) and `bp sites` damp
marks (the snapshot exports none). Water that seeped in without a damp cancel (a channel into a light aquifer) taught nothing
(05dc764 water.lua:1827 M.aq_level, sites.py:635 aquifer_well).

## Fix
The water scan reads the aquifer flag of the revealed tiles it already reads beside and in each body (snapshot.tile `aq`, FR-95:
revealed tiles only); such a level is kept (m.water `aqz`), logged once ('water sources: aquifer level zN (a revealed aquifer tile
at ...)') and handed to the runner (`runner.aq_seen` -> manifest `aquifer_levels`), so `bp sites cistern water=aquifer`, `bp sites
aqshaft` and the recipe ('an aquifer well ... z N') know it.

## Tests
`tests/lua/test_bug288_291_water_scan.lua` (an aquifer wall beside the water: runner told, M.aq_level, recipe). Fail on 05dc764.

## Live check
Inkintense: kern.log 'aquifer level z130'; `dfllm cmd inspect '{"what":"manifest"}'` aquifer_levels holds 130; `dfllm bp sites cistern
water=aquifer --fresh` ranks sites 'basin on aquifer level z130'. Uncertain: whether DF keeps the aquifer flag on the walls of a
channelled pit (if not, no level is learnt and an aqshaft must find it).
