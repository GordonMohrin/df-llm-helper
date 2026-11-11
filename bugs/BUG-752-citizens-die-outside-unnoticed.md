# BUG-752 a citizen away from the fort for days is not reported until he is found dead
Status: fixed (offline, live-untested)
Severity: medium (the report helps only if it exists while he lives)
Found: 2026-11-11, Run 16d i4 Pagedsculpture y386 (Rovod Okirdeduk 26368, militia captain, 'has been missing for a week', DEATH 'unknown, not found yet, missing in the unit list') and y391 (25769, 'missing in unit list', then found dead 'infection' at 150,129,137); `runs/run-16d/FR-BUGS.md` "Vermisst-Meldung (missing > 2 d) als Class-A Event".
Module: `lua/dfllm/seal.lua`

## Actual
The only event was DEATH (class B) after the fact; nothing said that a living citizen had been off the map, cut off or far out for days.

## Root cause
Nothing tracked how long a citizen stays away; CUTOFF fires only for a rise of cut citizens of a vital class, a trip job excused it, and a citizen on the connected surface far from the fort is on the main walk group.

## Fix
`seal.M.missing_watch` (in the `stray` job, every 600 ticks): a citizen counts as away when he has no position (`off_map`), stands on a walk group without drink and food (`cut`), or is outside Kern+ and farther than `CFG.missing_far` (40) tiles from every citizen inside (`far`). After `CFG.missing_after` (3 days) away: new event MISSING (A, seal) `{unit, why, pos (last position), job, days}`, text "citizen N away for D d (...): last at x,y,z, job J"; once per episode, again after `CFG.missing_again` (14 days); at most 3 per look. A wake hint is added.

## Open
Soldiers are not in sense's `outside_ids`, so a squad on a sortie is never 'far'. A fort with no citizen on a group with drink and food reports nothing. The cause of a death outside is not diagnosed.

## Tests
`tests/lua/test_bug751_752_strays.lua` "MISSING (A)": off the map and cut off for days, once, with position and job.

## Live check
A citizen who leaves for more than 3 days produces MISSING with his last position and job.
