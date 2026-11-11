# BUG-740 a militia captain keeps the Hunting labor and dies hunting outside; hunters go out with a predator at the water
Status: fixed (offline, live-untested)
Severity: high (a trained soldier lost; the fort held 16 citizens)
Found: 2026-11-11, Run 16d i4 Pagedsculpture y386 (`runs/run-16d/FR-BUGS.md`: Rovod Okirdeduk, 26368, Bone Carver and militia captain, "cancels Hunt for small creature: Could not find path", DEATH #3267, pos 129,119,110 on the surface)
Module: `lua/dfllm/economy.lua` (`tools`, `hunt_want`, `M.soldier_hunt_off`), `lua/dfllm/act.lua` (`LABOR_SETS.hunt`)

## Actual
Rovod joined the Hunters detail (#425), left it when he became a captain (#462) and was later a squad member (O1 station moves, y385). The kernel never looked at his Hunting labor again: he walked out on a vermin hunt, was cut off by a wall (CUTOFF/STRANDED on groups 4990, 1708, 17) and died of thirst on the surface. Nothing kept the hunters inside while a wild predator stood at the water.

## Root cause
- `economy.tools` (the details loop): a Hunters member that is a squad member is "not eligible" and was taken off only if the kernel had put him there (`mine[id]`); a player's entry stayed. No pass looked at the HUNT labor of a unit on no detail.
- `economy.hunt_want` never read `census.w.hold` (sense's water-beast hold), which keeps only the fishers home (BUG-494).

## Fix
- `economy.tools`: a squad member is taken off the Hunters detail whoever put him there (`sq`, the `elseif mine[id] or sq` branch).
- `M.soldier_hunt_off` (end of `tools`): every squad member with the HUNT labor on loses it, `act.labor_set(id, 'hunt', false)` (new `LABOR_SETS.hunt`, off only), once a day per unit and 3 a pass; WORK_DETAIL (B) why 'soldier'.
- `hunt_want`: `census.w.hold == 1` gives 0 hunters, why 'predator', also in a famine; `tools` treats 'predator' like 'siege' (off the detail at once, every member).

## Tests
`tests/lua/test_bug740_hunters_outside.lua` (fail on 5006f415): a squad member the player put on the detail is removed, a soldier with the labor loses it once, a predator hold takes the hunters off at once and releases them. `tests/lua/test_bug546_547_acts.lua` (the act's message). No gate, bridge or lockdown code is touched; the siege traffic tests of the suite pass unchanged.

## Live check
A soldier with the Hunting labor: one WORK_DETAIL why 'soldier'; a WATER_PREDATOR near citizens: the Hunters detail empties in the next run.
