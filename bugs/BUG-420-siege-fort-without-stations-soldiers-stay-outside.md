# BUG-420 a fort without a fortcore manifest has no station: the squads stay where they are in a siege
Status: fixed (offline, live-untested); open: the recall of 26 outside workers took 6666 ticks (the alarm itself was on time)
Severity: critical (Ostgate fell, 83 -> 0, in a 40-goblin siege)
Found: 2026-11-05, Run 16b i2 Ostgate y401 (`E:/DF-test2/dfllm-runtime/r16b-ostgate-site97/kern.log` lines 2106-2260), main b4087f4
Module: `lua/dfllm/military.lua` (`pick`, `posture_station`, `note_pick`)

## Actual
The request: "the alarm came only at sighting; recall the outside workers early, hold the soldiers inside Kern+ at stations rather than
'station 0' outside". The log says otherwise about the alarm:
- 161712393 (the popup "A vile force of darkness has arrived!"): `civ alert: Kern+ (28 citizens outside Kern+)`, `recall: 26 citizens outside
  Kern+ at the alert`, ARRIVAL siege/invasion/invader in the same step (INTRUDER 18 hostiles 45 tiles away at 1,153,138). Alert, clock and
  recall began at the announcement, 5 ticks before SIEGE_START; the army reached Kern+ at 161722380 (BREACH), 10,000 ticks later. All 26 were
  in at 161719059 (6666 ticks, the farthest stood 50 tiles out), before the breach.
- The soldiers were the hole: `siege: deep defense: ... every squad at the core station (none in the manifest)`; 161714227 `1829 ticks
  into the SIEGE only 0 of 15 soldiers stand at their stations (nost 15): the orders are issued again`. The fort had no fortcore (5 years),
  so its manifest holds no `stations` and no Z4 zone: `station_of` gave a chain, `pick` resolved no entry (`r.first` nil), and
  BUG-214's Kern+ fallback needs `r.first` (it runs only after a wall / walk-group failure). No squad got any order; 15 soldiers fought
  wherever they stood, the civilians died around them.

## Root cause
`lua/dfllm/military.lua` `pick` (the fallback block at its end): `if o.fallback and hard and r.first` - a chain whose entries have no position at all
returned an empty result.

## Fix
`pick` takes `o.core_floor` (set by `posture_station` for READY_STATION, B2_HOLD, READY_IN and CORE; not for the peace-time inner station and
not for INTAKE, whose field station is its own): with no entry resolved and no position found, the squad is ordered to the nearest Kern+ floor
to the middle of the burrow (`kern_floor`: revealed, on the squad's walk group, clear of any bridge, inside the burrow). STATION_MOVED
(B) `why core` and a kern.log line say `no station in the manifest: the squads stand on the nearest Kern+ floor ...`. kpi `on_station` then counts
them and siege's re-issue / `stationed` see them.

## Open
- The recall: 26 citizens at up to 50 tiles need 6000+ ticks; "+N out since the alert" shows citizens leaving Kern+ again after it sounded (a
  hospital, food, a bed outside the burrow: not diagnosed). The wake is early already; a faster recall needs the cause of the re-leavers.
- The refuge: Tiefe+ was refused for lack of drink (`REFUGE_FAIL no drink, no well`), patients lay outside the alert burrow (PATIENTS_OUT).

## Tests
`tests/lua/test_stations.lua` (BUG-420: manifest without stations/zones, SIEGE, a station order inside Kern+, STATION_MOVED core, kpi nost 0).

## Live check
A fort without a fortcore in a siege: `dfllm events --type STATION_MOVED` shows `why core`, the squads have a `station@` inside Kern+, siege no
longer says `only 0 of N soldiers stand at their stations (nost N)`.
