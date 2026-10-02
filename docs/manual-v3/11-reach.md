# Reachability watcher: `dfpilot reach` (spec v3-11)

Status: implemented, **not yet live-tested**. Read only.

Checks that the fort's work and supply places (farms, kitchens, stills, well, hospital, barracks, ...) are still
reachable from the core. Run 5: two emergency plugs cut the farms off for years and nobody noticed.

## Commands
| Command | What it does |
|---|---|
| `python -m dfpilot reach` | measure all points (one `claude/pilot_reach check` call); for unreachable mandatory points: cause search |
| `python -m dfpilot reach what-if --wall X Y Z [--wall ...]` | before building a wall/plug: would it cut off a mandatory point? exit 1 = yes/unprovable |
| `python -m dfpilot reach correlate [--gamelog FILE]` | gamelog cancels (`Could not find path`, `Needs ... spawn`) -> point category -> unreachable points |
| `python -m dfpilot reach points` | list the watch points (`*` = mandatory) |
| `--grid fixtures/v3/grid/reach_p1p2_built.grid` | offline on a grid fixture (`@core`/`@point` lines) instead of live DF |

Exit codes: 0 all mandatory points reachable / what-if safe; 1 unreachable / what-if warns.

## Example (fixture "P1/P2 built")
```
UNREACHABLE: F1, F3, F4, F5, Kitchens, Stills (cut at (101,99,z130))
F1 (106,92,z132): cut by construction (101,99,z130), (100,94,z132) -> remove it (designate 'remove construction') or replace it with a door
farm: 493x 'Plant Seeds: Needs plump helmet spawn' (43 dwarves) -> F1, F3, F4, F5: cause certain (point unreachable + many cancels)
```

## Watch points: `data/reach.yaml`
```yaml
start: [100, 101, 130]
points:
  - {name: "Farm hall F1", xyz: [106, 92, 132], cat: farm}
  - {name: "Depot", xyz: [112, 98, 133], cat: depot, optional: true}
```
The shipped file holds **example values from run 5** - replace them for every fortress. A point is mandatory when its
`cat` is in `reach.mandatory` (unless `optional: true`), or explicitly with `mandatory: true|false`.

## Configuration (`reach:` in config.yaml)
`start`, `points_file` (data/reach.yaml), `interval_s` (300), `mandatory` ([farm, kitchen, still, well, hospital,
barracks]), `margin` (6, dump box around start + points), `max_tiles` (150000), `cancel_min` (20), `in_check` (true).

## In `dfpilot check`
Every `interval_s` one measurement. Lines only while mandatory points are unreachable (digest line + cause/correlation,
each <= 120 chars) and once when everything is reachable again (`Reachable: 7/7 mandatory points (again)`).
Unreachable points also raise a critical warning (`reach:unreachable`, wakes the orchestrator). Actions are logged in
the store (`source=reach`, actions `measure`, `what-if`).

## How it works
- `claude/pilot_reach check sx sy sz x,y,z ...` -> `canWalkBetween` per point (walk groups, cheap).
- `claude/pilot_reach dump x1 y1 z1 x2 y2 z2` -> one character per tile (encoding in `dfpilot/features/_grid.py`);
  unrevealed tiles are `?`. Python does a 0-1 path search where constructed walls cost 1: the constructions on the
  cheapest path are the cutting ones.
- what-if adds the planned walls to the dump and compares reachability before/after. A point that is reachable live
  but not inside the box counts as "cannot prove" (unsafe).

## Limits / open live checks
- Building ID and build date of a cutting construction are not available (constructions are no buildings; DF does
  not log them). Doors are walkable; locked doors are not modelled.
- Liquids count as not walkable in the dump (conservative).
- Live: Lua against DF 53.x (`canWalkBetween`, `dfhack.buildings.findAtTile`), runtime for 20 points, dump size.
