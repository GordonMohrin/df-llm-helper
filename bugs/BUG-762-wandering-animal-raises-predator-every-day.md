# BUG-762 one wandering wild animal raises PREDATOR every day or two
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16a i1 Basementflew y530-y534: one Kelenken (34951, later 35430, 7-11k cm3) walked the whole map: PREDATOR #26758..#26910 every 1-2 game days, each a Kern+ lockdown with the clock at 30 t/s in between, the sorties followed it in vain; Run 16b i2 Whirledrampart: a Megalania and a woolly mammoth the same
Module: `lua/dfllm/reflex.lua` (`inside_scan`, `wander_raise`, `wander_note`, `clock_step`)

## Actual
events.jsonl of i1: PREDATOR (class A) for unit 35430 with `dc` 43 / `da` 39 tiles, then PREDATOR_FAR at 77 / 76 / 43 tiles, then PREDATOR again, around the clock. `reflex.REARM` (1200 ticks) only spaces the event inside one episode; a roamer that leaves and returns starts a new episode every time.

## Root cause
`lua/dfllm/reflex.lua` `inside_scan`: a wild danger within `predator_near` (40) of any citizen (`da` counts Kern+ too) is a PREDATOR, whatever the unit did before. The unit's history was not kept.

## Fix
Per-unit memory `rt.wild[id]` = {t last raise, d nearest distance at a raise, n raises, s last seen, c last tick it counted as PREDATOR} (forgotten after `M.WANDER_FORGET` = 40 days unseen). `wander_raise`: a unit that is still counted as PREDATOR (the same episode: out of the count for no more than `M.WANDER_CONT` = 600 ticks) stays one; a unit that raised PREDATOR before and came back is raised again only when it comes closer than at its raises by more than `M.WANDER_STEP` (6) tiles, or, after only one raise, `M.WANDER_DAYS` (4) game days later; otherwise it is counted as PREDATOR_FAR (no lockdown; the event says `roamer, PREDATOR raised N times`, field `roam`). Always immediate: inside Kern+ / past B1 (`zn` 2, `ik`), within `M.WANDER_CLOSE` (15) tiles of a citizen, a killer (`kl`), a building destroyer walking into the fort (`bd` / `pd`), the refuge (`rf`), distance unknown. `reflex.predator_near = 0` keeps the old rule. `clock_step`: the clock of a lockdown that only an unacked PREDATOR made is released after `M.WANDER_CLOCK_DAYS` (1) day instead of 3 while only a roamer is left in the count.

## Open
A first sighting is still a PREDATOR (and its default lockdown, 60 s unacked); the memory is runtime only (a Kernel reload forgets it). The hysteresis uses the distance sense reports (nearest citizen on its levels), not the walking distance.

## Tests
`tests/lua/test_bug762_roamer.lua` (once, then held back at the same distance; closer by more than the step raises again; farther holds back; 12 tiles is immediate; after `WANDER_DAYS` again, then only closer; inside Kern+ immediate; a killer immediate; siege traffic: an invader army still gets ARRIVAL and INTRUDER at once while a roamer is held back). `test_reflex.lua` (Run 10 PREDATOR_FAR, BUG-554, BUG-495, predator_near 0) and the siege suites pass unchanged.

## Live check
Basementflew: PREDATOR for a roaming animal at most once per approach; PREDATOR_FAR `roam` for the repeats; the clock back at normal speed a day after the lockdown.
