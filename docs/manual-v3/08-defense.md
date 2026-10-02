# Defense designer (`python -m df_llm_helper defense`) – spec v3-08

Status: implemented, **not yet live-tested**. The Lua part (`lua/pilot_defense.lua`, installed as
`claude/pilot_defense`) is read-only and LIVE-UNTESTED.

## Commands
| Command | What it does | DF access |
|---|---|---|
| `python -m df_llm_helper defense design --terrain <file> [--door x,y] [--access x,y] [--lane-len N] [--no-niche] [--stock stock.json] [--out DIR] [--name defense] [--csv]` | Designs lane, walls, traps, shooter niche; prints sketch, materials, missing stock, stages; writes `<name>.csv` + `<name>.txt` with `--out` | none |
| `... defense design ... --apply --confirm` | Builds: copies the CSV to `defense.blueprint_dir` (if set) and runs `quickfort run claude/<name>.csv -n /<label> -c x,y,z` for `walls`, `traps`, `niche` | quickfort (build orders) |
| `python -m df_llm_helper defense status [--file status.json]` | Stone traps loaded/empty, open load jobs, mechanisms/trap components/boulders in stock; `!!` and exit code 1 below `reload_warn_pct` | `claude/pilot_defense status` (without `--file`) |
| `python -m df_llm_helper defense stats [--gamelog FILE] [--tail N]` | Trap lines in the gamelog (caught/hits/load messages) vs. attack lines; warns on attacks without any trap message | reads the gamelog file |

`--apply` without `--confirm` is refused (exit 2). `design` alone never contacts DF.

## Terrain file
```
# SYNTHETIC ... (a comment containing SYNTHETIC marks the fixture)
origin: 90 86          # x y of the first grid character
z: 133
door: 99 94            # stair/door into the fort (lane starts next to it)
access: 99 113         # where attackers arrive
grid:
###.............___
```
Characters: `.` floor (buildable), `#` rock, `_`/space open air, `^` ramp, `> < X` stairs/door, `T` existing trap,
`B` building, `~` water. Dump the real level with `claude/area` and convert it (live check open).

## Example (synthetic Run-5 plateau)
```
python -m df_llm_helper defense design --terrain fixtures/v3/defense/plateau_z133.txt --stock fixtures/v3/defense/stock.json
python -m df_llm_helper defense status --file fixtures/v3/defense/status_12_of_20_empty.json   # -> !! 12 of 20 stone traps empty
```
Result on the fixture: lane of 20 tiles from (99,95) south to y109 and east to the mouth at (104,108); 12 Ts, 6 Tw,
2 Tc = 20 mechanisms; 53 Cw + 3 CF; cursor (98,93,133).

## Stages
0 check access (`claude/zugaenge`, spec v3-01) + quicksave; 1 walls (door side first); 2 traps (order mechanisms and
trap components first); 3 niche (CF, rack, stand; stair from z-1 by hand; squad "shooters" station); 4 `defense status`.

## Config (`defense:` in config.yaml)
`lane_len 20`, `wall Cw`, `trap_mix {Ts: 0.6, Tw: 0.3, Tc: 0.1}`, `shooter_niche true`, `reload_warn_pct 70`,
`components_per_weapon_trap 1`, `bars_per_component 3` (assumption), `blueprint_dir ""`, `blueprint_name defense`.

## Open live checks
Real z133 tiles; "loaded" detection of stone-fall traps in DF 53.16 (heuristic: boulder among contained items, or an
open load job; raw `state`/`ready_timeout` are reported); job type name of the load job (matched on "stone trap" +
"load"); gamelog trap message texts; quickfort keys `CF`, `r`, `a` and `-n /label`.
