# BUG-623 `hospital furnish=1` is 'taken by' the finished hospital room it furnishes; the DECISION offers no working command
Status: fixed (offline, live-untested)
Severity: medium (a hospital with patients and no table for 3 years, `no_table` every year)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y426-y428 (`runs/run-16d/FR-BUGS.md` 'BUG Hospital-Tisch (BUG-581)' and 'OBS Runde 37 ... Wirkung')
Module: `dfpilot/cmd.py` (`Occupancy.clash`, `Occupancy.furnish`, `is_furnish`, `_planned_only`), `dfpilot/wake.py` (`hospital_supply_hint`), `lua/dfllm/water.lua` (`M.SUPPLY_FIX`)

## Actual
`plan propose` drafted `hospital furnish=1` (BUG-581), `plan check` / `bp.place` refused it: `only 0 free site(s) ... 17 ranked; taken by y373s2b1 (hospital finished)`, and the hint said `y373s2b1 is planned hospital (not begun)` beside 'finished'. `bp.cancel y373s2b1` answered 'no project'. The DECISION `hospital_supply` carried no command for `no_table`.

## Root cause
`cmd.py` `Occupancy.clash`: the table tile lies INSIDE the hospital room, whose own project (y373s2b1, done, its tiles stay in `occupancy`) owns every tile of the room and its 8-neighbourhood, so every ranked tile was a clash with it. `_planned_only` called a project with no kernel state row 'not begun' although a PROJECT_DONE event said it was finished. `water.lua` `SUPPLY_FIX.no_table` had `nil` for the command.

## Fix
`Occupancy.clash` for a furnish document (`is_furnish`: tpl hospital, p.furnish) does not count a hospital project that is no furnish project (the room itself); a second furnish project on the same tile is still a clash (looked up by id, the room owns the tile in `owner`). `_planned_only` is False once PROJECT_DONE exists. `SUPPLY_FIX.no_table` offers `dfllm cmd bp.place '{"tpl":"hospital","site":"S1","p":{"furnish":1}}'`; `wake.hospital_supply_hint` names it instead of 'build it inside the zone'.

## Tests
`tests/test_bug623_625_f40_econ2.py` (4 for BUG-623), `tests/lua/test_water_m1.lua` (BUG-537 test: the command list)

## Live check
In Trumpetrealms (`no_table`): `dfllm cmd bp.place '{"tpl":"hospital","site":"S1","p":{"furnish":1}}'` queues one table; the next hospital audit has no `no_table`.
