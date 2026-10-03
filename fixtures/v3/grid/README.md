# Grid fixtures (specs v3-01 perimeter, v3-02 digcheck, v3-11 reach)

**All files here are SYNTHETIC**, rebuilt by hand from the run-5 notes (LAYOUT-run5.md, chronicle); none is a live dump.
Format and tile characters: `df_llm_helper/features/_grid.py` (`--` comment, `@origin x0 y0`, `@core`, `@point`, `@allow`,
`z <level>` + rows; unlisted tiles are natural wall). The same characters come out of `claude/pilot_reach dump` and
`claude/pilot_digcheck dump`, so a live dump can later replace a fixture 1:1.

| File | Situation | Real / assumed |
|---|---|---|
| reach_p1p2_built.grid | plugs P1/P2 built: farms, kitchens, stills cut off | real: core, P1, P2, F1, F3, kitchens, stills; assumed: corridors, stair, F4/F5, hospital stand-in |
| reach_p1p2_removed.grid | P1 replaced by a door, P2 removed | as above |
| perimeter_j109_open.grid | J109 before sealing: T1, stub stair, 23-tile north opening | real: T1 (99,94,z132), stub stair (96,88), north row z131, core; assumed: extents, corridors, traps |
| perimeter_j109_sealed.grid | after sealing (walls on the north row and next to the stub stair) | as above |
| dig_north_opening.grid | terrain before the farm-hall stage z131 y70..77 | assumed hillside/sky layout |
| dig_river_diagonal.grid | access F=(184,43,z128), river water diagonal | river tiles from LAYOUT-run5.md 11; aquifer wall synthetic |
| dig_cavern_unreachable.grid | underground void, isolated rock, construction, unrevealed tiles | fully synthetic |
| refuge_j125.grid | refuge burrow = hospital only (J125); `@burrow`/`@target` lines for `refuge check/repair --grid` (FEATURE-005) | real: well (139,99,z129), drink store (117..121,88..92,z132), food store (109..113,108..114,z130); assumed: hospital, corridors, stair (106,100) |
| gamelog_run5_cancels.txt | 493x "Needs plump helmet spawn" (43 dwarves), 41x "Inappropriate dig square" (29 dwarves), 12x depot path | counts real, names/order made up |

Fixture gaps (to fill from a live session): real `claude/pilot_reach dump` of the farm area with P1/P2, real
`claude/zugaenge` / `pilot_perimeter` output before/after sealing, tile dumps of the north opening and the river bank,
a real gamelog excerpt with the cancel lines, timing of the perimeter scan on the full run-5 map.
