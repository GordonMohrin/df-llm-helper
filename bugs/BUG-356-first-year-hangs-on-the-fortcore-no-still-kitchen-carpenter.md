# BUG-356 first year hangs on the fortcore: no still, kitchen or carpenter until stage 1 is dug, drink 0 d in every new fort
Status: fixed (offline, live-untested): `workshops surface=1` (the startup shops on open surface floor), drafted by plan
propose in year 1 beside the fortcore's stage 1; open: the water source zone (not built)
Severity: high
Found: 2026-11-04, Run 16a-d (`runs/run-16a/FR-BUGS.md` "Fortcore Stufe 1 haengt, Werkstaetten/Still/Kueche unplatzierbar",
16b "Hungersnot y372 Winter", 16c "Fort ohne Werkstatt", 16d "Werkstaetten: bp sites ohne --fresh meldet 0 Standorte"), main 595364a
Module: `dfpilot/bp/rooms.py` (workshops), `dfpilot/bp/sites.py` (`_surface_shops`), `dfpilot/plan.py` (propose),
`dfpilot/cmd.py` (_place), `lua/dfllm/runner.lua` (kind_of)

## Actual
Every new fort (13 citizens, no workshop on the embark) went through its first year with nothing to brew or cook with:
i1 'Kueche/Still abgelehnt (Fortcore noch nicht gegraben)' (`bp.place` workshops refused 'only 0 free sites'), drink 3 d -> 0,
food 22 d, 9 of 11 dwarves idle; i3 'rooms open from the dug Z4 floor' (workshops, farms, bedrooms stood at 50 %), drink 161 d
-> 30 d in four days; i4 Carpenters/Farmer/Clothier/Loom missing, 16 orders stuck, `bp sites workshops` 0 ranked until
`--fresh`. The player waited for fortcore stage 1 (30-189 days at s1.dig/s1.build in i1, i3).

## Root cause
Every workshops placement is a room dug from the fort's public Z4 floor (rooms.py `workshops` -> `_box`: dig + door +
burrow; sites.py `rank`: 'room sites need the fort manifest with zones.Z4', `_rooms`), so before the fortcore's stage 1 is dug
there is no site (`no_site_hint`: 'rooms open from the dug Z4 floor of the fortcore') and, in `place()`, the shops the
undug fortcore PLANS in its manifest fragment (wc, wm, wl, wz) were skipped as 'already planned'. propose in year 1
(plan.py BUG-197/354 reduction) drafted the seal and the fortcore only, so nothing in the plan or the kernel put a still,
kitchen, carpenter or mason on the ground the citizens stand on.

## Fix
- rooms.py `workshops` p.surface = 1 (default 0): no dig, no door, no burrow; one build stage, 3x3 cells four a row on the
  surface; without skip/add exactly STARTUP = Still, Kitchen, Carpenters, Masons; `only=` and skip/add pick others; the 5x5 shops
  refused. The manifest lists the shops, so the later full `workshops` project skips what stands.
- sites.py `_surface_shops`: needs no manifest; block of revealed floor with open sky above on one level, on the citizens'
  walk group (snapshot wg, BUG-352), off the manifest's keep-out tiles, rooms, workshops and the way in; nearest the middle
  of the snapshot (the wagon), `--near x,y,z --within N` moves it, +60 within 25 of the entrance.
- cmd.py: the surface set keeps Still and Kitchen the undug fortcore plans (no 'already planned' skip), the no-site hint
  names a flat block of open floor instead of the fortcore.
- plan.py propose: the year-1 draft (no Z4 floor, with or without a placed core) adds `workshops p={surface:1}` after the
  fortcore stage 1 and the seal, once (fort fact `startup`); build_kind 'supply' (also runner.lua kind_of) so an open seal does
  not pause the first year's drink.
- Not built: the water source zone for a reachable brook (the citizens drink from the brook while no still stands).

## Tests (fail on 595364a)
tests/test_bug356_358_startup.py (template, sites, placement beside the planned core, hint, propose, build_kind).

## Live check
New fort after adopt: `dfllm plan propose` drafts seal, fortcore stage 1 and `workshops surface=1`; `dfllm bp sites workshops
surface=1 --fresh --near <wagon x,y,z> --within 40` ranks blocks on the surface; the four shops stand in the first days, the
Still brews from gathered plants (BrewDrink orders), `status` drink days rise.
