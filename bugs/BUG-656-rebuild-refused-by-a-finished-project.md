# BUG-656 `workshops rebuild=1` is refused 'taken' by the finished project that built the room
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16a i1 Basementflew y464: `bp.place tpl=workshops site=S1 only=Kitchen rebuild=1` -> refused 'taken [78,100,131] by c1a1ab437a0e153311 (workshops finished)', while the kernel's own hint (BUG-562, 'bp.place workshops only=<Type> rebuild=1 builds it again there') and `gone_shops` (plan) send the player to exactly that command
Module: `dfpilot/cmd.py` (`rebuild_free`, `_place`)

## Actual
The surface kitchen 78,100,131 stood in `manifest.gone` (destroyed); the rebuild ranked its old place (`sites._rebuild_shops`: open floor, clear of the standing shops, on the citizens' walk group), then `_place` found the footprint inside the tiles of the FINISHED workshops project that had built it and refused. A finished project has no kernel row (`bp.cancel` answers 'no project'), so nothing could free the place.

## Root cause
`dfpilot/cmd.py` `_place`, `scan()` (and the explicit-anchor branch): `occ.clash(doc)` counts every project in `<save>/bp`, finished or not (BUG-549 narrowed only the explore probes and aqshafts). A rebuild digs nothing, it puts ONE shop back where it stood.

## Fix
`cmd.rebuild_free(save_dir, tpl, params, hit)`: for `workshops` with `rebuild` the hits that are FINISHED (a PROJECT_DONE event, no row in the kernel's state) are dropped; a project still under way keeps its tiles, a plain placement is unchanged. The old place is still refused when its footprint is not open floor now, a standing shop overlaps it or it lies on another walk group (`_rebuild_shops`): right for the old kitchen of z117, where a new one is asked for instead (BUG-654).

## Tests
`tests/test_bug654_656_f43_cook.py::test_a_finished_project_does_not_hold_a_rebuild_a_running_one_does`.

## Live check
Basementflew: `dfllm bp sites workshops --fresh`, then `bp.place workshops site=S1 only=Kitchen rebuild=1` accepts the surface place 78,100,131 when its 3x3 is open floor; a refusal now names the footprint or the walk group, not a project.
