# BUG-638 A seal for a hatch on solid rock (never-dug stair) stands for months and blocks plan acceptance
Status: fixed (offline, live-untested); open: the fortcore manifest keeps the never-dug refuge
Severity: medium (SEAL_STUCK / DECISION seal_stalled every month, `plan check` ERROR 'stair enters Tiefe+ without a hatch' for a stair that does not exist)
Found: 2026-11-10, Run 16b i2 Valleyhame y376-y377 (seal y376s0b1 / y377s0b1 'hatch 107,88,126: nothing stands at 107,88,126', build_lost twice, the DECISION offered cancel + place of the same `at`), Run 16c i3 Wallfree y374-y378 (seals y374s0b0 / y376s0b0 for the hatch 67,44,139 of a stair the stalled fortcore never dug)
Module: `lua/dfllm/runner.lua` (`Q.phantom_cells`, `Q.phantom_doc`, `Q.phantom_scan`, bp.place), `dfpilot/cmd.py` (`phantom_tiles`, `refuge_stair`)

## Actual
The seal's target tile was read from the fort manifest (refuge stair head); quickfort places nothing on rock ('nothing stands at'), the piece is never built, the project ends build_lost, and the DECISION / `plan check` ask for the same seal again. `refuge_stair` (BUG-123/124) knew `nostair` only from a revealed snapshot tile; with no snapshot (BUG-639) or a hidden tile it demanded the hatch ('as given').

## Root cause
No check of a seal piece against the map in the kernel: `open_pieces` / `piece_built` (runner.lua) count a piece open until a building stands, whatever the tile is. `cmd.refuge_stair` (`c0 is None` branch: 'unknown, as given') trusted the manifest when the snapshot had no word.

## Fix
`Q.phantom_cells` reads `snapshot.tile` for the unbuilt build cells of a seal: '#' / smoothed 'S' (solid rock) is a phantom (hidden tiles say nothing, a tile with a building is not counted). `bp.place` refuses a seal whose every piece is a phantom (`Q.phantom_doc`, with the reason and `bp sites seal --fresh`); `Q.phantom_scan` (end_run, PEACE) cancels a placed seal that is build_lost or SEAL_STUCK and whose unbuilt pieces are all phantoms (PROJECT_BLOCKED `d.phantom` = ['x,y,z #'], once). `cmd.phantom_tiles` reads those events (2 game years); `refuge_stair` returns `nostair` for the manifest head when it is such a tile and the snapshot does not show a stair there: `plan check` stops asking for the hatch, a stair dug later is demanded again.

## Tests
`tests/lua/test_bug638_phantom_seal.lua` (2), `tests/test_bug637_641_f41_proj.py` (phantom event ends the refuge demand, a dug stair brings it back)

## Live check
`bp.place` of a seal at a stair head on rock answers `refused: nothing to build on`; an older seal like y374s0b0 disappears with one PROJECT_BLOCKED `phantom`; `plan check` loses the refuge-hatch ERROR; `dfllm cmd inspect what=refuge` still lists the manifest refuge (open).
