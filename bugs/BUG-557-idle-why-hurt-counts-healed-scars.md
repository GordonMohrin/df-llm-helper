# BUG-557 idle_why `hurt` counts every dwarf with a healed scar (13-20 of 25 adults "injured")
Status: fixed (offline, live-untested)
Severity: medium (wrong report; the idle analysis was unusable, the recruit and patient tests used the same rule)
Found: 2026-11-06, Run 16d i4 Trumpetrealms y404 (`runs/run-16d/FR-BUGS.md` "idle_why hurt zaehlt jeden Zwerg mit einer alten Narbe": `idle 20 = hurt 20` of 25 adults, `inspect what=unit` `wounds 1`, bleed 0, blood 100 %; read only)
Module: `lua/dfllm/economy.lua` (`M.idle_flags`), `lua/dfllm/util/wound.lua` (new), `lua/dfllm/military.lua` (`healthy`, `patient`)

## Actual
`inspect what=workload` / `brief`: `idle 76 % (hurt 16)`; almost every dwarf has one wound on `unit.body.wounds` that healed long ago.

## Root cause
`economy.lua:2496` (before) `local wounds = b ~= nil and #b.wounds > 0; f.hurt = wounds or (care and bled)`: `unit.body.wounds` keeps every wound of the unit's life as a scar. BUG-271 had removed the health care flag alone; the list length stayed. `military.healthy` (`#u.body.wounds == 0`) and `military.patient` (`#u.body.wounds > 0`) used the same test: a scarred dwarf was no siege recruit and a "patient".

## Fix
`dfllm.util.wound`: `state(u)` reads the wounds' parts (`parts[j].bleeding`, BUG-137), the health care flag and the blood; `needs_treatment(u)` is true when a wound has a bleeding part, a wound's parts cannot be read, or the health care flag stands with a wound on the list or lost blood. `idle_flags`, `military.healthy` and `military.patient` use it. A scar (parts at bleeding 0, flag off) is no hurt and no patient.

## Tests
`tests/lua/test_economy_idle.lua` (two scars, one bleeding wound, one scar with the care flag: hurt 2; `needs_treatment` false for the scars).

## Live check
`inspect what=workload` on a fort of scarred dwarves: `idle_why.hurt` counts only bleeding or flagged ones.
Open: a wound that does not bleed but needs a doctor (broken bone, infection) is seen through the health care flag only; the flag's value for old scars could not be checked offline.
