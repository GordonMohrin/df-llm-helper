# BUG-604 `plan propose` / `plan check`: the kept fortcore and the core placed by hand count as two ("is the fort's fortcore already")
Status: fixed (offline, live-untested)
Severity: medium (no year plan can be applied until the year changes: PLAN_EXHAUSTED)
Found: 2026-11-09, Run 16c i3 Wallfree y372 winter d20 (bp.cancel of the plan's fortcore, `bp.place fortcore aquifer=pass` by hand, then every draft, even without fortcore entries, failed until the new year)
Module: `dfpilot/plan.py` (`place_all`, `_kept_core`)

## Actual
`plan check` / `plan apply`: ERROR "fortcore stage 1: <id> (anchor ..) is the fort's fortcore already; a second one digs and queues beside it for weeks".

## Root cause
The plan applied for the year keeps its builds at their indexes (`stable_ids`, `rebase_on_applied`): the cancelled `y372s0b0` (fortcore@S1 stage 1) stays in every draft of that year, also in one with the fortcore entries removed (they are put back). `place_all` treats a kept build whose bp file is gone as new (`todo`) and places it; `cmd._place` (`dfpilot/cmd.py:2167`, BUG-358) refuses a stage 1 while another fortcore stage 1 stands, i.e. the core placed by hand. `stale_core_keys` (BUG-366) helps only when no fortcore project is on file.

## Fix
`plan.place_all` (`plan.py:5178`, `_kept_core`): a kept (same-year) fortcore stage 1 build with no project file, while the bp folder holds a fortcore stage 1 (`cmd.first_core`), is that core: not emitted, the line says `kept <id> ... (BUG-604: ... was cancelled, this core stands in its place)`, and the core's anchor / rot are the `same` for the later fortcore stages of the draft. A stage 1 with no kept build at that index (a fresh draft) is still refused (BUG-358).

## Tests
`tests/test_bug602_606_f39.py` (2: the kept stage 1 is the core that stands, a fresh draft is still refused; a stage 2 at `same` lands on the standing core's anchor)

## Live check
After `bp.cancel` of the plan's fortcore and a hand-placed core: `dfllm plan propose` / `plan check` of the same year shows `kept <core id>` and no fortcore ERROR.
