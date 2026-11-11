# BUG-730 The automatic drill repeats a gear-only failure at 30 t/s and starts with citizens outside; mechanism orders nobody can make
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16d i4 Trumpetrealms y374 (DRILL_FAIL 'worn<90, outside:1/8' several times in a row, clock 'held 30 t/s reason drill' instead of 450, plan projects frozen / stalled); Run 16d i4 Pagedsculpture y373-y374 (traps 'suspended by buildingplan: waits for trapparts x1' for months, ConstructMechanisms orders x2, x13, x8 'no job for 12 days')
Module: `lua/dfllm/drill.lua` (`check`, `gear_hold`, `outside_hold`), `lua/dfllm/economy.lua` (`mech_labor_note`, order check, `T.stale`)

## Root cause
- drill.lua `check`: after a failed drill the retry came after a month (doubling to a season) whatever the failure; a drill that failed on the gear alone (`mech` 1: the bridges rose, only worn < 90) failed the same way again, each one an hour at the drill's 30 t/s cap. Nothing looked at the citizens outside Kern+ before a start: the settle phase cannot recall one the fort keeps outside, it ended `outside:1`.
- economy.lua: a ConstructMechanisms order with no worker holding the Mechanics labor was only reported (ORDER_STUCK 'no worker MECHANIC'); `mechanic_labor` (BUG-546) was called only for lever link jobs.

## Fix
- `drill.gear_hold`: the newest drill failed on the gear alone and worn has not risen `GEAR_STEP` (10) points above its result, nor reached 90, nor a year (`GEAR_RECHECK`) passed: held as `gear: worn N<90` (state ready.dhold); `drill.outside_hold`: a due automatic drill waits while a citizen stands outside Kern+, for `OUT_FORCE` 7,200 ticks of it at most (`outside: N`), then starts and recalls as before. The player's `drill` is unchanged.
- `economy.mech_labor_note` (`mechanic_labor` + a note): the order check calls it for a stuck ConstructMechanisms order with no worker, the stale pass adds it to the reason (the labor goes on for the best idle candidate once a day while nobody holds it).

## Tests
`tests/lua/test_bug730_drill_holds.lua` (3): the pure hold rules, one gear-only failure and no automatic retry in 80,000 ticks (`gear: worn`), the outside hold and its OUT_FORCE end; `tests/lua/test_bug730_mech_labor.lua` (3): the labor goes on once and kern.log says so, nothing changes when somebody holds it, the note's words.

## Live check
state `ready.dhold` reads `gear: worn N<90` / `outside: N`; no DRILL_FAIL streak of `worn<90`; kern.log 'Mechanics labor on for unit N' when mechanisms wait. Open: the traps wait also for stone the game calls 'non-economic' (BUG-545, trade.want stone / mechanism); `plan_mech` already orders the parts (BUG-435), here the missing dwarf is added; 10 points / a year / 7,200 ticks are judgements; a drill held for 'outside' never starts while somebody stays outside for good, past OUT_FORCE it does.
