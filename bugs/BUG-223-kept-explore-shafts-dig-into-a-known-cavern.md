# BUG-223 kept explore shafts dig into a cavern level the kernel recorded after the apply
Status: fixed (offline, live-untested; Python part only)
Severity: medium (each shaft into the cavern costs a BREACH_STOP, an A wake and a plug)
Found: 2026-10-29, live round 4, i-test3 "Earthboat" (FRICTION-explore-cavern)
Module: `dfpilot/plan.py` (`fit_explore_kept`, `run`)

## Actual
The first apply placed explore shafts for all four seasons (depth 12, z135 -> z123). After s0b0 broke into a cavern (CAVERN_PLUG #2388) the
kernel recorded z123 in manifest.caverns, but the second propose kept the applied explores unchanged ('Builds kept ... stay as they are'),
so y380s2b0 broke into z123 again (BREACH_STOP #2620, PROJECT_BLOCKED #2692). fit_explore fits new builds only.

## Fix
`fit_explore_kept` (propose CLI): for each explore kept from the applied same-year plan with no PROJECT_DONE, its bp file's anchor z and
depth give the shaft; a manifest.caverns level inside it gives a line `explore <id> (depth D from zA) reaches the known cavern level zN
(manifest caverns): dfllm cmd bp.cancel proj=<id>, then propose again (...)` and a short note. The kept build itself is not changed
(stable_ids). Not done here: the runner re-check of a placed explore against manifest.caverns before its dig starts (Lua).

## Tests
`tests/test_bug220_223_cli.py::test_kept_explore_reaching_a_known_cavern_level_gets_its_cancel`, fails on 5e9e719.

## Live check
A fort with an applied explore not yet dug and a cavern breach in manifest.caverns (`dfllm cmd inspect what=manifest`): `python -m dfpilot
plan propose <scratch>/p.json` prints `explore y<Y>s<S>b<I> ... reaches the known cavern level z<N> ...: dfllm cmd bp.cancel proj=...`.
