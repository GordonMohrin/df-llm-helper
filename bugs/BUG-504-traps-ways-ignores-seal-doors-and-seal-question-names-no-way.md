# BUG-504 `traps at=ways` says "no way in left ... 0 doors" although the seal built doors; the seal question names no remaining way
Status: fixed (offline, live-untested)
Severity: medium (R1 wants traps >= 30; plan check / propose drafted no lanes; the wall question was answered blind)
Found: 2026-11-05, Run 16b i2 Roadvises y376-y377 (`runs/run-16b/FR-BUGS.md` "FR traps at=ways 'nothing to trap' trotz traps<30", "OBS seal stalled am Fortcore-Eingang"; read only)
Module: `dfpilot/traps.py` (`seal_doors`, `lanes`, `expand`), `dfpilot/bp/traps.py` (`ways_in`), `lua/dfllm/seal.lua` (`M.opening_ways`), `lua/dfllm/runner.lua` (`Q.seal_escalate`)

## Actual
After `seal at=last` built the doors 75,78,139 and 79,85,139, `traps at=ways: no way in left to trap ... (0 door(s) between the outside and the fort, 0 trapped)`. The seal question (DECISION_NEEDED seal_stalled) said "recommended where the citizens keep another way: wall the tile" with no check and no way named.

## Root cause
- `bp/traps.py ways_in` takes the inside of a door from tiles reached from the manifest boxes (`fort_boxes`) with doors closed. The doors of a surface seal lead into the fort's yard, which is in no manifest box (the fort geometry lies underground), so no door had an "inside" neighbour: 0 doors. The sites snapshot may also predate the door.
- `runner.lua seal_escalate` (~line 3873) printed the wall recommendation without asking `seal.opening_ways` which ways stay (`others` was only used by the stuck-wall fallback).

## Fix
- `traps.seal_doors(save, snap)`: the door cells (`d`) of the finished seal projects (PROJECT_DONE); a snapshot older than the project that shows floor there is drawn with the door (a copy). `bp.traps.ways_in(..., seal_doors)`: for such a door any walkable tile the outside does not reach counts as its inside; without manifest boxes the door search still runs. `traps.lanes` (facts, plan check) and `traps.expand` (`at=ways`) use it.
- `seal.opening_ways` returns `where` (up to 3 other openings with a door or bridge, `x,y,z door|gate`); the question names them ("they keep 30,30,9 door, 20,25,9 gate (2 other ways ...)"). A known check with no other way: no wall command ("no wall: the entrance check names no other way ..."). Not known: the old command with "the entrance check is not known: look at inspect what=entrances first".

## Tests
`tests/test_bug501_505_f31.py` (3: lanes / expand count the seal door, the snapshot patch (not when newer, snapshot unchanged), no finished seal = the old refusal), `tests/lua/test_bug503_505_sealreach.lua` (4: `opening_ways` `where`, the three question texts). Fail on d756064.

## Live check
`dfllm bp sites traps` / `plan check` after a seal built doors: lanes for them. A `seal_stalled` question for a wall: `how` names the ways that stay or says "no wall".
Open: the seal DECISION for a perimeter that stays open does not list the open ways in general; this fix names the remaining way for the wall option.
