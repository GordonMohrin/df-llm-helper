# BUG-510 A siege with 15 goblins and a cave dragon: B1 held by one animal, unequipped soldiers stationed and refilled from civilians, pop 99 -> 31
Status: fixed (offline, live-untested); the dry refuge and the open perimeter of that fort are NOT fixed here (see Open)
Severity: critical (47 killed + 19 bled in about 2 game days, soldiers 21 -> 2)
Found: 2026-11-06, Run 16a i1 Basementflew y406 summer (FR-BUGS "Belagerung y406 Sommer"); runtime `r16a5-basementflew-site97/events.jsonl` #5081-#5498 and `kern.log` ticks 163884298-163910000 (read only)
Module: `lua/dfllm/gate.lua` (`holders`, `drop_animals`, `approach`), `lua/dfllm/military.lua` (`hold_floor`, `squad_fit`, `unfit_text`, `standdown`, `apply_squad`, `squad.sortie`, `kill_lone`), `lua/dfllm/siege.lua` (`station_watch`, `sortie`)

## Actual (from the events and kern.log)
- #5081-#5087 tick 163884298: siege popup, invasion 4, SIEGE_DEEP "1 building destroyer in sight (CAVE_DRAGON x1)", the alert on Innen+ (Kern+ refused: drink 53<99; Tiefe+ refused: no drink, no well).
- kern.log 163884804 "B1 up waits for animal 27877 walking onto it in 13 steps", "B1 raise held 495 ticks"; 163885545 "B1 up pull cancelled: animal 27877 3 tiles from it and walking toward it"; #5107/#5108 tick 163885550 BREACH "B1 not up at T+900". One tame animal held the raise for the whole first 1,242 ticks.
- #5113 ambush popup 1,400 ticks into the siege; goblins take the doors of the open surface halls (#5136 "Door toppled", #5137 "Innen+ breached (hostile inside at 134,89,131)"); #5115-#5300: STRUCK_DOWN deaths, mostly `patient` (hospital none), #5199 13 in a day, #5386 36 in a day (killed 24, bled 10).
- kern.log 163886136 "1828 ticks into the BREACH only 0 of 13 soldiers stand at their stations (far 1, hurt 6, level 6)"; 163889230 "SIEGE refill: squad A 1 -> 5 of 5 with healthy civilians from the core" and "militia turnover ... worn 61% before, 0% now"; the gear line "weapon 4/13 no bars", SIEGE_DEEP "worn 0% < 60%"; FR: 2 of 19 soldiers fully equipped, metal 0.
- #5498 SIEGE_END "26 hostiles, 7 killed, 68 lost, soldiers 19 -> 5, on station 0". B1 itself rose only at tick 163891530, "7221 ticks after the pull was queued".

## Root causes (code)
1. `gate.lua holders` (BUG-335/492): every unit, a tame animal too, that walks onto the footprint within CROSS_REACH steps (or stands beside it) holds a SIEGE/BREACH raise, and since BUG-492 a walker holds to the end (GATE_FAIL `blocked`). A pet pacing at the gate kept B1 down until T+900 -> BREACH. `M.approach` cancelled the taken pull for it as well.
2. `military.lua hold_floor` (Run 11 siege 3): in a siege the first melee squad is refilled up to HOLD_MIN (5) "beyond the gear" from healthy civilians. With 4 weapons in the fort those recruits had no armor or weapon (worn 61 % -> 0 %).
3. `military.lua apply_squad` / siege `SIEGE_DEEP`: whatever the gear, every squad was ordered to the core station (and `squad.sortie` / `kill_lone` / the gate sortie only looked at the squad's `worn` %, which counts assigned slots, not who holds a weapon and wears body armor).
4. (BUG-511) the pull itself: the pullers needed more than the 600 ticks they got.

## Fix
- `gate.lua`: `M.drop_animals`: in the timed modes (SIEGE, BREACH, DRILL) a tame animal (scan kind `animal`) beside the footprint or walking onto it no longer holds an `up` raise (`holders`, `M.approach`); one ON the footprint holds until the deadline escape (CROSS_HELD of DEADLINE = 450 ticks), after that not even that (an animal is crushed rather than the fort lost). Citizens, soldiers, visitors keep the BUG-310/492 rules.
- `military.lua`: `hold_floor` reaches HOLD_MIN only as far as `gear_sets` go (at least GEAR_FLOOR 2): no recruit without kit; `M.squad_fit` / `standdown`: in a SIEGE/BREACH a squad of which fewer than `UNFIT_PCT` (30 %) hold a real weapon AND wear body armor gets no station (order cleared, routine off duty, so the civ alert keeps it with the civilians in the refuge), kern.log `squad A stands down: 0 of 3 ...` / `is equipped again`; `M.unfit_text`: `squad.sortie`, `kill_lone` and `siege.sortie` (the gate sortie) refuse such a squad with the numbers; `military.kpi().sd` counts the soldiers standing down and `siege.station_watch` leaves them out (no "0 of N stand at their stations" re-issue storm). PEACE and DRILL are untouched.
- Not changed: the kill orders of the crossbow squad in the killboxes; the soldiers' sortie `worn` threshold (80 %) stays.

## Tests
`tests/lua/test_bug510_513_siege.lua` (3, SIEGE traffic with citizens, soldiers and a pacing / standing animal at B1: B1 up by T+900, the animal on the footprint holds only until the escape, the gate closes behind the stream, nobody crushed, no GATE_FAIL/BREACH; all 3 fail on the old gate); `tests/lua/test_bug510_unfit.lua` (4: stand-down, re-equipped, PEACE/DRILL untouched, refusal text, `squad.sortie` refused); `tests/lua/test_military_refill.lua` (the Run 11 siege 8 test changed: refill to the gear sets; +1: with gear for HOLD_MIN it is reached); `test_siege` (animal on B1 leaves at 300), `test_gate_footprint` (merchant), `test_intake`, `test_military`, `test_m3_sortie`, `test_bug140_sortie_dead`, `test_bug169_kill_order` adapted: their soldiers are equipped now.

## Live check
SIEGE with a pet near B1: no "B1 up waits for animal ..." for more than the first frame. A siege in a fort with 4 weapons: `military: SIEGE: squad A stands down: N of M soldiers hold a real weapon ...` in kern.log, no "SIEGE refill ... of 5" beyond the sets, `squad.sortie` answers `sortie refused: squad A is not equipped: ...`.

## Open
The fort of this siege was R0-unready before it began (SIEGE_UNREADY #4937: open_perimeter, audit_fail, bypass, refuge_sep, refuge_dry, no_outer, traps_short; 0 traps, no stone, Tiefe+ without a well, the civilians held in the open halls the goblins entered). Nothing in gate/military can replace a dry refuge, a closed perimeter or traps; a siege's casualties there are mostly that. The REFUGE_SWITCH Kern+ -> Tiefe+ #5222 with 16 hostiles visible (BREACH over "sealed") walked the population through the fight; not touched.
