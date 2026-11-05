# BUG-500 The planner drafts the temple and the cistern again although altar and mechanisms are impossible
Status: fixed (offline, live-untested)
Severity: medium (builds at 37 % for years that block rooms and phases, a plan that cannot be made smaller)
Found: 2026-11-05, Run 16a i1 Basementflew R9 ("Planer schlaegt Temple/Cistern wieder vor obwohl Mechanismen/Altar fehlen; angewendeter Plan nicht verkleinerbar"), Run 16d i4 (stone 0)
Module: `dfpilot/plan.py` (`nostone_reason`, `drop_impossible`, `stone_gate`, `cancelled_ids`, `stable_ids`, `rebase_on_applied`, `fort_facts`)

## Actual
The temple's offering place is a stone altar and a cistern's well, lever and floodgate need mechanisms; both are stone. In a fort with no free boulder (or a soil fort) `propose` drafted them again from the phase list and the stress response, and after the player cancelled the projects (`bp.cancel`) the applied plan still listed them: `stable_ids` refused any plan that ended before an applied build ('keep it'), so the plan could not be shrunk and a draft built on it kept the cancelled builds.

## Fix
- `fort.nostone` (`nostone_reason`): the kernel's soil mark (state `stock.rsoil`) or `stock.rock` 0 with a current MATERIAL_SHORT; `fort.cancelled` = the ids in `bp/.cancelled` without a live bp file.
- `drop_impossible` (propose, follow, minimal plan): new temple and cistern builds are left out while `nostone` holds; a cancelled temple / cistern at the END of an applied season is dropped too (a build in the middle would shift the ids behind it and stays). The note names each one and the reason (altar / mechanisms) and says what comes first (trade.want stone, mechanism; the dig to hard stone).
- `stable_ids(doc, prev, free)`: the plan may end before a trailing run of cancelled builds (`check`, `rebase_on_applied`). `check` warns for a NEW temple / cistern while stone is out of reach (`stone_gate`).

## Tests
`tests/test_bug497_500_f31.py` (reason, leaving out with the note, a cancelled tail dropped and accepted by stable_ids, middle / live ones stay, the check warning).

## Live check
In a stone-0 fort `plan propose` prints 'BUG-500: stone is out of reach ... left out temple ..., cistern ...'; after `bp.cancel` of an applied temple at the end of its season the next propose is shorter and `plan check` says OK; stone arriving (rock > 0 or the MATERIAL_SHORT gone) brings them back.
