# BUG-388 'no dry fortcore site ... (wet level z130)': one stop rules out the whole level
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16b (i2 Ostgate `bp sites fortcore --fresh`, even at depth 2/1; also i1), main bb87afb
Module: `dfpilot/bp/sites.py`

## Actual
`no dry fortcore site: every site's dig lies within 10 tiles of a recorded breach (wet level z130 (...))` for every site and every depth of the
map after two damp/water stops (or one `heavy_aquifer`) on z130; the message says "within 10 tiles" but sites 90 tiles away were out too.

## Root cause
`sites._dry` (dfpilot/bp/sites.py, `near()`): a level in `_breach_layers` (2 damp/water stops or 1 heavy_aquifer on the level) was returned as the
reason for any candidate whose dig reached that level, whatever its x/y. In an aquifer world the layer spans the whole level, so one stop ruled
out the whole level (BUG-359 made one heavy_aquifer stop enough; its test was named `..._for_every_site`).

## Fix
A wet layer rules out the dig only within `LAYER_R` (16) tiles (x/y) of one of the stops on it (`near()`); other breaches keep `BREACH_R` (10)
and +-1 level. Beyond the radius the known-aquifer rating (`_flooded` penalty, `aquifer_ok`) still judges the level, and a core that breaches
anyway is re-sited or replaced by the surface core (BUG-387). The old tests that pinned the whole-level rule now pin the area.

## Tests
tests/test_bug387_389_surface_core.py::test_a_stop_rules_out_the_dig_near_it_not_the_level; test_bug130_damp_fortcore.py and
test_bug359_361_sites.py (rewritten wet-layer tests).

## Live check
i2-like: `bp sites fortcore --fresh` after two stops on z130 lists sites farther than 16 tiles from them (or, with the aquifer under every
site, plan propose drafts the surface core).

## Follow-up (verifier)
`_dry` only rules out digs within `LAYER_R` of a wet layer's stops, so a farther site could still dig into a breach-recorded wet level
at az-4..az-8 while `surface_core_why` (SURFACE_AQ 3) said no surface core was needed. `surface_core_why` now also returns a reason
when a breach-recorded wet layer lies in `[az-SURFACE_DIG (8) or the site's dig z0, az]`. Test: `test_surface_core_why_names_...` (az-5, az-9).
