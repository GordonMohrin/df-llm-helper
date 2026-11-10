# BUG-686 A way in on the perimeter waits for the player to type `seal at=last`
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16a i1 Basementflew ('PERIMETER OPEN 31 d (Treppe 88,96,130 + Wand 96,131,130), erst durch manuelles seal at=last angegangen; Kernel/follow hat nicht selbst gesiegelt'; 'jedes Mal von Hand schliessen; plan propose lehnt P5 bei offenem Perimeter ab'), Run 16d i4 Trumpetrealms y450-y454 ('Wunsch: ganzen Rim auf einmal als Mauer schliessen', 'Perimeter wandert: nach jedem Seal neue floor ways in'), earlier the same in 16c i3 and 16d i4
Module: `dfpilot/wake.py` (`Follower._check_perimeter`, `_place`)

## Actual
`follow` placed a seal by itself only for the walls of an AUDIT finding (`_request_seal`, BUG-211). The ways in the entrance check names without door or bridge (state `ready.ents`, SIEGE_UNREADY `ents`, `status` 'PERIMETER OPEN') reached the player as a wake, who typed `bp.place tpl=seal at=last` each time: weeks of open perimeter, the pop ceiling held, P5 refused.

## Root cause
No automatic path from `ready.ents` to `seal at=last`; the only automation was the audit's `at=audit`. (BUG-685 is why the openings kept coming; this is why none was closed without a human.)

## Fix
`Follower._check_perimeter` (every `PERIM_CHECK_EVERY_S` 120 s, only with auto): in PEACE, when the state's `ready.open` > 0 and `ready.ents` lists a way (readiness lists a tile only after two game days in the check's answer, never a sapling / shrub rim: BUG-600 / BUG-566), `cmd.seal_openings(save, 'ents')` is asked first (it raises when a seal project builds the tiles, a newer snapshot shows them closed or nothing is open: nothing is placed, no snapshot is requested), then the seal at=last goes out through the normal job path (`_request_place('perim', 'seal', {'at': 'ents'})`, snapshot, `bp.place`, reply read, AUTO_FAIL on a refusal) at most once per `PERIM_COOLDOWN_S` 1,800 s. Door or wall is the template's rule (a door beside a wall, a wall otherwise; the kernel's reach check refuses a wall that would cut citizens off, WALL_REFUSED, and `seal_openings` gives that tile a door the next time: BUG-487). Up to `dmod.SEAL_MAX` ways go in one project, the rest on the next look. A placement that finds nothing to close any more (`SealClosed` at place time) is logged (`auto:perim`) and is no AUTO_FAIL. Never in a siege / breach / alert (state mode must be PEACE), never with `--no-auto`. cli.log: `auto:perim`.

## Restriction (verifier)
`at=ents` is new: `seal_openings` takes `current_openings` and keeps only the entries with src `ents` (the plain ways in of the last entrance check), so follow never walks a SEAL_LEAK, refuge or young / sapling / shrub rim entry that `at=last` would add; walls and doors cannot pile up on a moving unconfirmed rim. The placed project stores the resolved tiles.

## Tests
`tests/test_bug686_perimeter_auto_seal.py`: places the seal at=ents with the real templates on the fixture snapshot (bp file `100,127,122 floor`), nothing again while its project covers the tile; no placement in SIEGE / BREACH, with `--no-auto`, or with nothing open; the look interval; a `SealClosed` at place time is no AUTO_FAIL; `at=ents` skips a SEAL_LEAK tile that `at=last` includes (5 tests). Siege traffic: no bridge, gate, lever, refuge or lockdown code changed in this fix (the seal template and its reach check are the existing ones: `test_bug503_505_sealreach.lua`, `test_bug564_568_siege_traffic.lua`); the traffic test of the companion change is in BUG-685.

## Live check
With a way in without door in `status`: cli.log shows `auto:perim` within ~2 minutes of follow's look, a seal project (door / wall per the note) appears, `status` clears after the build and the next entrance check; `plan check` passes P5 without a hand-placed seal. With `follow --no-auto` the wake keeps saying 'auto-seal off'.
Open: follow, not the Lua kernel, places it (the blueprint is a Python template); with no follow running nothing is placed, as before. One project per look closes at most SEAL_MAX ways; a rim of many mouths takes several looks (30 min each). The seal piece goes where the entrance check names the way, also in the forest at the map edge (a door there is what the players placed by hand); BUG-685 removes the shade rims, so what remains are real mouths.
