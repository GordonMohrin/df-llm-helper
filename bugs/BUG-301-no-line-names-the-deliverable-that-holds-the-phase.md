# BUG-301 no status, brief or doctor line names the deliverable that holds the phase
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15 round 3 (Drillchamber; runs/run-15d-drillchamber/FR-BUGS.md 'Runde 3')
Module: `lua/dfllm/runner.lua` (phases, M.state), `dfpilot/brief.py`, `dfpilot/doctor.py`

## Actual
Drillchamber: status line 1 said ` P0` for six game years; the player session had to guess why ("farms 0 Sites?
probe? hospital?") and could not tell which of the five P0 deliverables failed. Root cause: runner.lua:3781
(`check_phase`) returned only pass/plan_fail, nothing kept which deliverable failed; brief.py:114 (`line_head`) shows the
phase id alone and doctor said nothing about phases.

## Fix
runner: state `phw = {wait, waived}` (<= 4 each): the deliverables of the phase the check stopped at that are not met
(`farms`, `fortcore 2`, `workshops Still,Butchers` = the missing types, `squads 3`, `stock drink_d>=170`), and the waived
ones (`farms: <why>`, BUG-300). status (rank 2) and brief (plan section): `phase P0: waits for workshops Still (farms
impossible: bp sites farms: 0 room and 0 surface sites -> waived)`; doctor adds the command for a deliverable that can
never be made: `dfllm cmd phase.waive '{"tpl":"farms","why":"<what makes it impossible>"}'`. Contracts: state `phw`
(owner runner).

## Tests
`tests/lua/test_bug300_phase_waive.lua` (state phw, check_state), `tests/test_bug300_302_phase.py` (line_phase, status,
doctor). Fail on 9ef2ccb.

## Live check
`dfllm status` in any fort below its plan target: `phase Pn: waits for ...`; `dfllm doctor` the same line with the
phase.waive hint. Guildcleans (P1): expected `workshops Jewelers,MetalsmithsForge,Bowyers,Clothiers+4` in the wait list (its manifest lacks
8 moodable shops), perhaps `dining` before it.
