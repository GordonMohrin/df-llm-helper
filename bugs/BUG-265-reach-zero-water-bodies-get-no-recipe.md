# BUG-265 Water bodies 10-29 tiles from the hospital with reach 0 get "a cistern" instead of a dig or a pipe to them
Status: fixed (offline, live-untested)
Severity: medium (the recipe points nowhere while water is near)
Found: 2026-10-29, Run 15 Earthboat (HOSPITAL_DRY #171/#324) and Drillchamber (body 141,67,143 n=158 reach 0), fix6-water
Module: `lua/dfllm/water.lua` (`M.DEFAULTS.ws_dig`, `M.recipe`)

## Actual
HOSPITAL_DRY #171/#324 `no reachable water >= 4/7 within 30 tiles` while 6 water bodies lay 10-29 tiles away, all `reach 0` in
`inspect water_sources`. The scan's dig search stops at `ws_dig` 8 walls; a body without a bank and without a dig within 8 got the
generic "a cistern (bp sites cistern)".

## Fix
`ws_dig` 16 (config `water.ws_dig`, 0..50; `ws_reads` still caps the tile reads per body). A body within `near` that has neither a
bank nor a dig is named with a piped cistern to it: `the water at x,y,z (n/7, d tiles) has no bank and no dig within 16 walls: a
cistern piped to it (python -m dfpilot.bp.sites cistern --near x,y,z)` (plus the aquifer well when an aquifer level is known, BUG-262).

## Tests
`tests/lua/test_bug262_266_water.lua` `BUG-265 ...` x2 (fail on 2b9c009).

## Live check
Earthboat: the next HOSPITAL_DRY names a dig (`dig N wall tile(s) from ...`) or `a cistern piped to it ... --near x,y,z`;
`python -m dfpilot.bp.sites cistern --save <folder> --near x,y,z` routes the pipe.
