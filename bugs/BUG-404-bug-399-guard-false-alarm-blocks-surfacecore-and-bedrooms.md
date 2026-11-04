# BUG-404 BUG-399 guard false alarm keeps surfacecore and the surface rooms out
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16b (i2 Ostgate y396-y397, `runs/run-16b/FR-BUGS.md`), main 503bb8b
Module: `dfpilot/bp/sites.py`

## Actual
`bp sites surfacecore`, `workshops surface=1`, `bedrooms/dining/tavern surface=1` (also `bp.place ... site=S1`): 'its top level z138 holds
1865 floor tiles but no level above it to show open sky (BUG-399 ...)'. The draft had no surface core and no bedrooms, 28 homeless,
PROJECT_REQUEST bedrooms x20. `office surface=1` found 4 sites at the same time (surface z131); an explicit anchor label worked.

## Root cause
`sites.py` `rank` (surface_shops branch): the BUG-399 guard raised whenever the ranking was empty and the snapshot's top level held
>= 25 floor tiles. In Ostgate the box reaches z138, a mountain peak with 1865 floor tiles, while the open surface lies at z131: the
box does not end at the surface, the sky is in the snapshot, and the empty answer was a genuine 'no valid site' (block too big, bedrooms n=10).
The condition only looked at the top level.

## Fix
`sites.sky_over_floor(snap)`: True when any floor tile has an open-sky tile directly above it anywhere in the snapshot. The guard
fires only when it is False (the box ends at the surface, the BUG-399 case); otherwise the ordinary error follows.

## Open
A real lack of room for the surface core / ten bedrooms is still 'no valid site' (smaller `n`, another template).

## Tests
tests/test_bug403_405_plan_order_guard.py (guard silent with a peak above the surface, still fires when the box ends at the surface).
