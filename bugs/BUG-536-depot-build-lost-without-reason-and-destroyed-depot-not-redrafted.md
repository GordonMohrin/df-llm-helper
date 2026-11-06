# BUG-536 A depot project stays build_lost with "missing D" and no reason, and `plan propose` never drafts a depot again after a tantrum
Status: fixed (offline, live-untested) for the naming and the proposal; why quickfort refused the live site is not proven
Severity: medium (no caravan trades for years, 16 retries and two parked projects on the same 5x5)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y385-y389 (`runs/run-16d/FR-BUGS.md` "OBS Tantrum zerstoerte das Handelsdepot"; events #4905 BUILDING_TOPPLED Trade Depot 84,78,139, #5481 / #5586 y386s0b2 and #6272 / #6854 y389s0b2 "build_lost at build, missing D", kern.log "retry 8/8 (a season passed)", read only)
Module: `lua/dfllm/runner.lua` (`piece_name`, `Q.lost_why`, `blocked_event`, `Q.park_event`), `dfpilot/plan.py` (`depot_planned`, `depot_lost`, `_parked_ids`)

## Actual
PROJECT_BLOCKED said `build_lost at build, missing D; retry 1/8 ...` for a depot at 65,74,141 (manifest `depot` [67,76,141]); both the y386 and the y389 project failed on the same site and nothing named a cause. `plan propose` y386 and y389 had no depot although the old one (84,78,139) was toppled.

## Root cause
1. `runner.lua` `piece_name` returned the raw cell key (`D`) for anything but a bridge, lever or trap; `missing_pieces` looks at the first tile of the 5x5 only; the seal reasons (`remake_why`) are for seal pieces, nothing explained a building that quickfort places as a whole.
2. `plan.depot_planned` (BUG-368) answered "a depot stands or is under way" from the kernel manifest (`depot`, never cleared when the building is lost: `snapshot.lua:749` copies what the fort recorded) and from any `depot` bp file, finished or parked. A toppled depot (BUILDING_TOPPLED, DEPOT_MISSING) and a depot project parked for good both kept `fort.depot` true, so the BUG-368 rule in `propose` ("no depot standing, planned or coming") never fired.

## Fix
1. `M.BIG_PIECE` names `D` "trade depot"; `Q.lost_why` reads the footprint of a missing multi-tile building tile by tile (`snapshot.tile`: wall, tree, ramp, stair, open air, water, magma, another building; hidden counted) and, for the depot, `economy.mat_for('depot')`; the text goes into PROJECT_BLOCKED (message and `d.parts`) and the park announcement. A clear footprint with material says so ("looks clear and material exists: quickfort refused the site; place it elsewhere"); only hidden tiles say nothing (the retry text already does).
2. `plan.depot_lost` (newest of BUILDING_TOPPLED of a trade depot / DEPOT_MISSING against the newest PROJECT_DONE of a depot, fortcore or surfacecore project) makes `depot_planned` ignore the manifest and finished depot projects; a project the kernel parked (`state.proj` row `parked: ...`) never counts. A depot project that runs still does. `fort.depot_lost` adds the reason to the proposal's note.

## Tests
`tests/lua/test_bug536_538_runner.lua` (3), `tests/test_bug535_538_f33.py` (3).

## Live check
`PROJECT_BLOCKED` of a lost depot names `trade depot` and either the tiles or "looks clear"; after a depot was toppled `plan propose` has `depot@S1` with `BUG-536` in its notes.
Open: the chosen site of the two failed projects is not known to be bad (the sapling notes nearby suggest plants or trees); `depot_lost` needs one of the two events (a depot lost before an older save was loaded is not seen).
