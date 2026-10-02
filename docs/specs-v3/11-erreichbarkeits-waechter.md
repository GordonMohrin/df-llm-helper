# Spec v3-11: Reachability watcher (`dfpilot reach`)

Priority: P0 | As of: 01.10.2026 (run 5, J110) | Status: **implemented (v3), not yet live-tested** (`dfpilot/features/reach.py`, `lua/pilot_reach.lua`, manual `../manual-v3/11-reach.md`); a manual check with `canWalkBetween` found the original fault | Framework: see `../specs-v2/README.md`

## Goal and benefit
Important work and supply places must stay **reachable** from the fort. The plugs P1 `(101,99,z130)` and P2 `(100,94,z132)`, built as an emergency measure during the first elf army (J105), cut off the stair column T1 and with it **all farm halls (F1 z132, F3/F4/F5 z131), kitchens and stills** from the fort. Consequence over many game days: planters did not find seeds ("Needs plump helmet spawn" 493x, 43 dwarves), no harvest, production only from traded goods. This was only noticed in a manual check, about 5 game years later.
**Expected gain:** prevents silent production failures; the diagnosis (about 12 calls) becomes one message.

## Watch points (`data/reach.yaml`)
Per point: name, coordinate, category, mandatory. Examples from run 5: farm hall F1 (106,92,z132), F3 (112,93,z131), kitchens (106,85,z132), stills (110,89,z132), well (140,99,z129), hospital (107,99,z128), barracks (90,100,z128), crypt, food/wood/ore stockpiles, workshops west (70,100,z130), depot (112,98,z133, optional), smelter. Start point: core (100,101,z130) or a citizen's location (bed).

## Behavior
1. **Measurement** (`pilot_reach.lua`): `canWalkBetween(start, point)` per point, in one call, cheap (< 1 s).
2. **Finding** for a mandatory point with `false`: message `critical` `Farm hall F1 (106,92,z132) not reachable from the core`.
3. **Cause search:** path search with/without constructions (walls/plugs) and doors: shows **which construction** cuts the connection (coordinate, building ID, build date from the gamelog); proposal: removal (`designateRemove`) or a door instead of a wall.
4. **Pre-check:** `dfpilot reach what-if --wall x y z` before a wall/plug is built; `perimeter seal` (v3-01) and `plan defense` (v3-08) always call it. Plugs that cut off a mandatory point are not built, or only with an explicit yes.
5. **Chain of effects:** jobs that fail with `Could not find path` or `Needs ... spawn` (gamelog) are attributed to a mandatory point; high count + point unreachable = cause certain.
6. **Digest:** `Reachable: 14/14 mandatory points` or `UNREACHABLE: Farm hall F1, Kitchens (P1 (101,99,z130))`.

## Configuration
`reach: {start: [100,101,130], points_file: data/reach.yaml, interval_s: 300, mandatory: [farm, kitchen, still, well, hospital, barracks]}`
(implemented additionally: `margin` (dump box around start + points), `max_tiles`, `cancel_min` (20), `in_check`)

## Fair play
Read only.

## Acceptance criteria
1. Fixture "P1/P2 built": reports F1, F3-F5, kitchens, stills as unreachable and names `(101,99,z130)` as the cutting construction.
2. Fixture "P1/P2 removed, door": all mandatory points reachable.
3. `what-if --wall 101 99 130` warns about cutting off the farms.
4. Runtime <= 1 s for 20 points.
5. Correlation: 493 "Needs plump helmet spawn" are attributed to the points F3/F4/F5.

## Fixtures/tests
Tile/path data before and after the plugs; gamelog excerpts ("Plant seeds: Needs plump helmet spawn", "Bring item to depot: Could not find path").

## Implementation notes (v3)
- Tests: `tests/test_reach.py` (one test per acceptance criterion, plus the live path through the Lua grid mock `tests/lua_mock/grid_mock.lua`). Fixtures `fixtures/v3/grid/reach_p1p2_built.grid`, `reach_p1p2_removed.grid`, `gamelog_run5_cancels.txt` are **synthetic** (rebuilt from the run notes; real coordinates for core, P1, P2, F1, F3, kitchens, stills; F4/F5 and the corridors are assumed).
- Cause search: `pilot_reach dump` delivers one character per tile for the box around start + points (+ `margin`); Python runs a 0-1 BFS where constructed walls cost 1 and lists the constructions on the cheapest path (F1: P1 then P2).
- **Deviation:** building ID and build date are not reported - constructed walls are `df.construction`, not buildings, and DF does not log finished constructions in the gamelog. The coordinate is reported instead.
- **Deviation:** the what-if check runs on the dump box; if a point is reachable live but not inside the box (detour outside), the result is "cannot prove" and counts as unsafe.
- Correlation uses only `Could not find path` / `no path` and `Needs ... spawn|seed` cancels (material shortages like "Needs logs" are ignored).
