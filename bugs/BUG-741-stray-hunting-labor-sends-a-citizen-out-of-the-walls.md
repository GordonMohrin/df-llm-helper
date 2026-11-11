# BUG-741 a civilian in no detail with the Hunting labor walks 70 tiles out on a vermin hunt and dies of thirst
Status: fixed (offline, live-untested)
Severity: high (a citizen lost; the unit came with the migrant wave of the season before)
Found: 2026-11-11, Run 16c i3 Doorwings y385 (`runs/run-16c/FR-BUGS.md` "STRANDED/CUTOFF bei ankommenden Migranten": 28225 Gem Cutter, job HuntVermin at 168,167,148, STRANDED on walk group 116 "no rescue (no raised bridge leads to drink and food)", thirst 75001, dead; the corpse lies on a tile with no walk group)
Module: `lua/dfllm/economy.lua` (`M.soldier_hunt_off`)

## Actual
The log shows no edge spawn: the unit arrived with the wave announced at tick 155257883, lived in the fort, and at 155471010 stood 70 tiles away in a pocket of the surface (tree crown, group 116, zone 17701 58 tiles off). No bridge could join it (STRANDED refused, `stranded_drink` DECISION) and the only cure the log names is a way (ramp or stair) to the unit, which the digging rules forbid near water and which a tree crown does not allow. The Hunters detail never held him (WORK_DETAIL lists others only), so a Hunting labor set outside the kernel's details (the unit's default or the labors screen) sent him.

## Root cause
Nothing looked at the HUNT labor of a citizen on no Hunters detail: `economy.tools` managed members only (`stray_tool` only for members). The labor is the cause of the trip (`HuntVermin` / `Hunt` jobs run outside); once the unit is in an unreachable pocket nothing can rescue him.

## Fix
`M.soldier_hunt_off` (BUG-740) also sweeps civilians: an adult citizen with the HUNT labor on, no squad, no member of the Hunters detail, loses it (`act.labor_set 'hunt'`, once a day per unit, 3 a pass, WORK_DETAIL why 'stray'). Not in a famine (`p.famine`: hunters are wanted) and not when the detail is on "everybody does this". A hunter the kernel or the player placed keeps the labor.

## Open
A unit already in an unwalkable pocket is still not rescued (a path to it is forbidden near water, a tree crown has no tile to dig). The source of the labor on the unit is inferred, the labors screen is not logged.

## Tests
`tests/lua/test_bug740_hunters_outside.lua` ("BUG-741"): the stray loses the labor once a day (why 'stray'), the detail member keeps it, a famine sweeps nobody.

## Live check
After a migrant wave: no new citizen carries the Hunting labor unless he is on the Hunters detail; no HuntVermin job outside the walls.
