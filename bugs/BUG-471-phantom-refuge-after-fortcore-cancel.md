# BUG-471 Run 16a i1 Basementflew y372-377: after bp.cancel of fortcore stage 1 and 3 the manifest kept the refuge z123 and the stair 98,87,124; the hatch was 'unreachable' 5x, plan check demanded the seal every year
Status: fixed (offline, live-untested); open: the live route of the i1 manifest entries is inferred from the code
Severity: high
Found: 2026-11-05, round 29 notes (`runs/run-16a..16d/FR-BUGS.md`), main 59d6abb
Module: lua/dfllm/runner.lua:M.unmerge_manifest, Q.undug_tile, remove

## Actual
`inspect manifest` still listed `refuge {anchor 94-102,84-90 z123, burrow Tiefe+}`, `stairs.civ` 98,87,124 and the fortcore's Z4 boxes after both projects were cancelled ('17 applied dig chunk(s) taken back'); nothing stood at 98,87,124. `seal at=refuge` stuck (SEAL_STUCK, 8 DECISIONs), `plan check` ERROR 'civilians' stair enters Tiefe+ below 98,87,124', refuge_sep / civ_sep / refuge_dry red for years.

## Root cause
`runner.remove` (the end of every `bp.cancel`) dropped the project and its records but never looked at the manifest: what a project's fragment had put there (fortcore stage 3: `refuge`, burrow `Tiefe+`, `stairs.civ`, Z4 boxes, rooms, bridges, stations) stayed for ever, although the tiles were never dug. (The fragment reaches the persisted manifest by `finish`, or by an earlier finished stage of the same core; the live route of the i1 entries could not be re-read, the runtime has been replaced by a new fort.)

## Fix
`runner.M.unmerge_manifest(man, frag, undug)`: refuge (and its role=refuge burrow), `stairs` (foot on the refuge level), `zones` boxes, `rooms` and `bridges` / `stations` that equal the cancelled project's fragment AND whose tiles read as solid wall (`Q.undug_tile`: the snapshot tile reads `#` or `S`; dug, unrevealed or unknown tiles keep their part). Called by `remove` for an unfinished project; kern.log `its undug manifest parts left the manifest (...)`.

## Tests
`tests/lua/test_bug469_473.lua` (pure function: undug / dug / unknown / foreign entry; the real `bp.cancel` path through the runner).

## Live check
After `bp.cancel` of an undug fortcore stage: `dfllm cmd inspect what=manifest` has no refuge / `Tiefe+`; `plan check` no refuge stair demand. A stage that dug the refuge keeps it.
