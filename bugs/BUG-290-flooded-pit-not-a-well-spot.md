# BUG-290 a flooded pit open above the water is not offered as a well spot
Status: fixed (offline, live-untested)
Severity: medium (Run 15 Inkintense: the captives pit 77,57,131 held water >= 4/7 on its ramp 77,57,130 in Kern+; nothing offered it)
Found: 2026-10-29, Run 15 round 2 (Inkintense FR-BUGS, snapshot s151801089-3)
Module: `lua/dfllm/water.lua` (scan_body, M.recipe, M.best_way)

## Actual
`scan_body` (05dc764 water.lua:824-899) looked only for a standable bank beside the water on its own level, then for a dig through
natural wall on that level. A pit (walls all round on the water's level, open above) had neither and counted as 'no bank and no
dig: a cistern piped to it'.

## Fix
Open space (`_`, or `v` over a channel's ramp) right above a body tile beside a standable floor the citizens reach on that level is
a well spot (`pit` = the well's tile, `stand` = the floor); not for cavern water, magma, or water that already has a well or zone.
The recipe offers it after a bank and before a dig: 'build a well at x,y,z over the water at ... (N/7, open above it, ... reachable)'.

## Tests
`tests/lua/test_bug288_291_water_scan.lua` (open tile and ramp top; out of reach: none). Fail on 05dc764.

## Live check
Inkintense: `inspect water_sources` body at 77,57,130 with `pit` [77,57,131]; HOSPITAL_DRY / state water.wsc 'a well at
77,57,131'. A well there turns the captives pit into a well (tell the player before building it).
