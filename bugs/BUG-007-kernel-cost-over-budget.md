# BUG-007 kernel cost 82-90 ms/s vs limit 25, `repeat` bucket unattributed, budget self-test always fails
Status: open
Severity: medium (PEACE ticks/s median 430-435 instead of 450+, KERNEL_SLOW demotions flip-flop, `selftest` reports a failure that never clears)
Found: 2026-10-15, Run 9 save autosave 1 (402 units, 18.7k items, 5-25 citizens), dfpilot main 3edc277
Module: perf / kern (budget), modules seal, sense, economy

## Actual
```
$ python -m dfpilot doctor
ticks/s median by mode over 2 min: PEACE 430 (412-474); last 412 pop 7 units 402 items 18743
kernel 87 ms/s avg, 109 max (limit 25); max frame gap 438 ms; gaps > 3 s: 0
modules ms/s: repeat 70.1 seal 36.7 sense 16.5 economy 11.9 kern 10.8 baseline 2.8 care 2.7 reflex 1.7
KERNEL_SLOW: economy demoted x4 / x8, care demoted x8, seal demoted x8, military demoted x4
verdict: PEACE median 430 ticks/s < 450; kernel 87 ms/s > 25
$ dfhack-run dfllm selftest full
dfllm selftest: 8 pass, 1 fail (budget)
kern.log: 19 x "selftest quick failed: budget" (every ~4 min), 1 x "state_fresh"
```
- `repeat` (70 ms/s, the biggest bucket) belongs to no module.
- `seal` costs 37 ms/s on a fort with 5-7 citizens.
- The same fort under the previous kernel had `kern` 7 ms/s (doctor) at the same item count, so the new modules cost ~80 ms/s.

## Fix proposal
Attribute `repeat` to the module that scheduled it (or name the scheduler), scale slice sizes with units and items, stop the
demote/promote flip-flop (demote once and keep until `ms_max` is low for N frames), and give the budget self-test a limit
that fits the fort or print the module that broke it.

Related: FR-62
