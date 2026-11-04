# BUG-387 aquifer world: no fort gets a core, every room template stands still (SURFACE CORE)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a-c (i1 Bachwald `runs/run-16a/FR-BUGS.md` lines 11-45, i2 Ostgate cli.log, i3 Yawninggilt), main bb87afb
Module: `dfpilot/bp/surfacecore.py` (new), `dfpilot/bp/rooms.py`, `dfpilot/bp/sites.py`, `dfpilot/bp/emit.py`, `dfpilot/plan.py`, `dfpilot/cmd.py`

## Actual
region1 has an aquifer nearly everywhere: i1 `bp sites fortcore` 0 ranked (aquifer z105-108 under surface z110), depth=1 placed anyway and
`breach:heavy_aquifer` at 4 % s1.dig; i3 sites 1-6 steps from water, `breach:heavy_aquifer` at 8-9 %; i2 `no dry fortcore site ... (wet level
z130)` at depth 3/2/1. Without a core: no Z4, so `office`/`dining`/`tavern`/`bedrooms`/`farms rooms` report `room sites need the fort manifest
with zones.Z4`, the manager validated nothing for 294 d (7 brews, 18 orders), drink 0, no refuge, forts stood still for years.

## Root cause
Every room template hangs on the dug public Z4 floor of a fortcore (`sites.rank`: `room sites need the fort manifest with zones.Z4`,
dfpilot/bp/sites.py:238); the only core is `fortcore` (dug, bp/fortcore.py), so when no dry fortcore site exists nothing can give the fort a core.
BUG-356/368/384 gave the shops, depot and hospital a surface variant, the core and the Z4 rooms had none.

## Fix
- New template `surfacecore` (bp/surfacecore.py, SURFACE kind like `depot`): a walled compound (constructed walls `Cw`, `w` x `h`, default
  21x15 + 6 rows apron) on open surface floor, nothing dug. Stages `s1.walls` (walls first: quickfort refuses a door beside none),
  `s1.build` (gate door, refuge door, 5x5 trade depot in front of the gate, dormitory beds, refuge beds), `s1.place` (food, wood, stone,
  furniture, refuse stockpiles, the trade pile), `s1.zone` (dormitory), `s1.burrow` (Kern+ over the interior, Tiefe+ over the walled 7x5
  refuge in the south-east corner). Manifest roles as the fortcore: `burrows` Kern+ (kern) and Tiefe+ (refuge), `refuge` {anchor, burrow},
  `depot`, `edge` (the tile before the gate), `zones.Z4` (the interior), a refuge room; no bridges (the kernel's gates do not apply).
- `rooms.dining/tavern/bedrooms/office` with `surface=1` (`_surface`): the same room and furniture, the dig and burrow stages dropped, every
  other tile of the room's bbox grown by one is a constructed wall (built first), the anchor stays the tile in front of the doorway; no Z4.
  `hospital` and `farms` already had `surface=1`.
- `sites.rank`: `surfacecore` and the surface rooms need no manifest; `_surface_shops` takes a local rect (the surface room's walls + the
  anchor row), rooms are ranked beside the manifest `depot` and off the surface core's Z4 box.
- `sites.surface_core_why`: why a dug core is out (no site, or a known aquifer level within `SURFACE_AQ` = 3 levels under the best
  fortcore anchor); used by `plan.surface_facts`. RANK_V 5 (cached rankings re-rank).
- cmd `no_site_hint` names the block for `surfacecore` and the surface rooms.

## Open
No bridge, no trap hall, no deep refuge: the surface core defends with the squads and doors (the kernel's seal/gate/readiness see Kern+,
Tiefe+, depot and edge only). Tombs, furnaces, temple, hall and the other templates that dig into rock have no surface variant (plan
propose leaves them out while the core is on the surface). Rooms are sited by the manifest `depot`; before the core is done they rank
by the middle of the snapshot.

## Tests
tests/test_bug387_389_surface_core.py (template x 4 rotations, params, 4 surface rooms, sites, area-only layers, facts, propose).

## Live check
i1/i2-like (aquifer): `bp sites surfacecore --fresh --near <wagon>` lists a site; `bp.place tpl=surfacecore site=S1`; `status`
proj surfacecore walls -> build -> place -> zone -> burrow done; manifest has Kern+, Tiefe+, depot; `bp sites office surface=1 --fresh`
lists a site beside the depot; `bp.place tpl=office surface=1`; the manager's brews validate.
