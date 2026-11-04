# BUG-421 a wild animal without the LARGE_PREDATOR flag kills citizens and nothing wakes
Status: fixed (offline, live-untested); open: the first victim is still unwarned (the animal counts only after a death)
Severity: high
Found: 2026-11-05, Run 16d i4 Mazelanterns y386 summer d1-d3 (events #4820/#4824, DEATH_CLUSTER #4825, `runs/run-16d/FR-BUGS.md`), main b4087f4
Module: `lua/dfllm/sense.lua` (`predator`, `consider`, `M.mark_killer`), `lua/dfllm/care.lua` (death handler)

## Actual
A wild platybelodon (a grazer) walked into the fort, interrupted eating and sleeping, struck down two citizens; the commander hit it with a
training spear. No INTRUDER, no PREDATOR, no lockdown; status `threat 0 vis`.

## Root cause
`lua/dfllm/sense.lua` `consider`: a wild unit is a hostile candidate only when `isDanger` or the caste has LARGE_PREDATOR (`predator()`); a grazer has
neither, so it is "wildlife" however many citizens it kills. `reflex.inside_scan` PREDATOR needs a census entry of kind `danger`.

## Fix
`care.lua` (the DEATH handler): a citizen killed by a unit (death incident `criminal`) calls `sense.mark_killer(id)`. `sense.mark_killer` (not a citizen,
not tame; 20 units at most) remembers the unit for 30 game days; `predator()` then counts it like a LARGE_PREDATOR (same walk-group and
entrance rules), its census entry carries `pr 1` (so `reflex.danger_why` calls it dangerous: no lone-harmless release, no 'size' excuse) and `kl 1`.
reflex's existing path then sends PREDATOR (lockdown clock + alert) when it stands on a roofed tile near the fort, PREDATOR_FAR (B) when far.

## Open
The first victim is not prevented. A wild creature that is attacking (no kill yet) is not seen: the unit's combat state is not read. The mark is kept
in memory (a kernel reload forgets it; the animal is marked again by its next kill).

## Tests
`tests/lua/test_bug420_422_alarm.lua` (sense: PEACE before, ALERT/danger/pr/kl after the mark, citizens and tame units refused; care passes the killer only).

## Live check
A citizen killed by a wild animal: kern.log `sense: unit N (...) killed a citizen: a wild danger from now on`, the next scan lists it as `danger` with `kl 1`,
PREDATOR in `alarm.txt` when it stands inside the fort; `squad.sortie` against its position as for any single danger.
