# BUG-584 Explore in a mudstone fort offers depth 2-6 sites beside the core again and again; nobody knows which rock the probes passed
Status: fixed (offline, live-untested)
Severity: medium (four probes y412-y415 found no ore and no hard stone)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y412-y415 (`runs/run-16d/FR-BUGS.md` 'FR Hartstein: Explore findet nichts in Mudstone-Fort')
Module: `dfpilot/bp/sites.py` (`_explore`, `EXPLORE_FAR`, `RANK_V` 11), `dfpilot/cmd.py` (`_with_explored`), `lua/dfllm/runner.lua` (`M.layer_mat`, `Q.shaft_rocks`, PROJECT_DONE), `dfpilot/schema.py`

## Actual
The ranking scored by steps to a stair and depth only; every new probe landed beside the earlier ones. A finished probe said nothing about its rock.

## Root cause
`sites._explore` score had no term for the earlier probes; the runner's PROJECT_DONE carried no rock data.

## Fix
`cmd.fort_manifest` adds `explored` (anchors of every explore bp file); `_explore` scores +8 per tile (up to 30) from the nearest earlier probe and the reason line says so; no earlier probe: ranking unchanged. The farther or deeper start still respects the avoided levels (caverns, aquifer, water marks). `RANK_V` 11 re-ranks cached sites. The runner reads the layer rock (tile-material GetLayerMat) along a finished explore's stair column: PROJECT_DONE message `rock: MUDSTONE z136-z131, LIMESTONE z130-z125` and `d.rocks` (schema `rocks:sa`).

## Tests
`tests/bp/test_bp_explore.py::test_bug584_...`, `tests/test_bug581_585_f37_econ.py` (`_with_explored`), `tests/lua/test_bug584_probe_rocks.lua` (2)

## Live check
`bp sites explore --fresh` after earlier probes: the first site names `N tiles from the nearest of M earlier probe(s)`; the next explore PROJECT_DONE lists the rock layers (needs DFHack `tile-material`).
