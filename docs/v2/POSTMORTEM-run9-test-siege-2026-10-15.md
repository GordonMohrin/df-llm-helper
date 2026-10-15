# Post-mortem: the first real siege on the Run 9 test fort (2026-10-15, y376 autumn)

Fort: copy of Run 9 autosave 3 (`test-siege-1524`, Udosoddom, region2-site96), played by Claude after Gordon's "starte". Kernel: main 95fe16d + the local trade fix.
Result: **50 citizens -> 1 in about 15000 game ticks, 38 of them killed by goblins, 2 bled, 46 "unknown" (found dead later).** The fort is lost.

## Enemy and timeline (ticks after the first ARRIVAL, 30 ticks/s while the lockdown held the clock)
| tick | what |
|-----:|------|
| 0 | popup ARRIVAL (siege), gates 0 of 4 up, lockdown starts, alert after the gates |
| ~600 | all four bridges up, civil alert on (`Kern+`), one door forbidden |
| 898 | first citizen dead (3 were outside `Kern+` when the alert came) |
| 1360 | `BREACH: hostile inside Kern+` |
| 1379 / 2697 | 3 / 10 deaths within a day |
| 14552 | last death; 1 survivor (a citizen in a strange mood) |
Attackers: 17 goblins, 2 cave dragons, 5 jabberers. The trade depot was destroyed in the same hours (`NO_DEPOT ... no known depot site`).

## What the kernel did (all as designed)
Recognised the popup in 2 s, held the clock at 30 ticks/s, pulled the four levers, raised all four bridges, turned the civil alert on after the gates, forbade the recognised door,
raised BREACH when a hostile entered the refuge, wrote 50+ events. None of this saved anybody: the refuge was the place the enemy walked into.

## Root causes
1. **The fort was never sealed.** `SEAL LEAK` named the same three openings from y370 on: the shaft head `55,62,117` (stair_updown, no door), the north ramp room `61,55,117` (floor), the east stair
   `75,70,117`. Only the east one has a door (74,70,117, whose forbid flag resets, BUG-015). Claude saw and documented the leaks (BUG-001/-002/-012) but did not close them while playing.
2. **The refuge is not a refuge.** `Kern+` is 6960 tiles on z108-112, the main halls with the bedrooms, workshops and stockpiles. The status line said `R0 fail: audit_old, audit_fail, bypass, refuge_sep, civ_sep, no_inner, no_outer`
   for the whole session; the audit passed on food/drink/beds only, never on "separated from the entrances". The alert then confined everybody to the area the enemy entered.
3. **No defense.** 7 soldiers without metal, skill below 30 (Claude had also discharged 9 unskilled ones an hour earlier to get workers), `traps 0` in the status line (46 traps stand only in the east trap corridor; the attackers used the other openings).
4. **The emergency refuge was missing and refused.** `Tiefe+` (the dead-end shaft 30,66,z80-108) did not exist. Claude painted it by hand at tick ~2500; the kernel refused it (`REFUGE_FAIL ... drink 0<8, food 0<8, beds 0<2`)
   and kept `Kern+`. Too late either way, 30+ were dead.
5. **Reaction time.** 1360 ticks from the popup to the breach (45 s real time at 30 ticks/s). Nothing a player does by hand helps at that speed once the openings are open.

## What worked
Hebel+ lever path, gate timing, door waiting for citizens outside, LOCKDOWN default after 60 s unacked, DEATH causes (`killed by goblin 26426 (STRUCK_DOWN)`), DEATHS_3PLUS, BREACH. The live tests of 95fe16d held.

## Lessons / follow-ups (written as bugs and feature requests)
- **FR-65 siege readiness is a gate, not a status line:** `R0 fail` with `refuge_sep`/`no_outer` must raise a class A `SIEGE_UNREADY` every game month and block "PEACE green"; the operator closes the openings first.
- **FR-66 auto-seal:** build doors (or walls) on the three `entrances` openings (quickfort `d`, forbidden items cleared) with a log line per piece; keep one door open only if a caravan route needs it.
- **FR-67 breach refuge:** when `BREACH` fires and no separated burrow exists, create the dead end behind the deepest stair automatically and accept it without food/bed counts for the first N days.
- **BUG-018** audit passes `Kern+` although it contains the entrances; **BUG-019** `REFUGE_FAIL` blocks the only reachable emergency burrow.
- Playing rule for the next fort: seal first, stock a refuge second, soldiers third; never discharge soldiers while the doors are open.
