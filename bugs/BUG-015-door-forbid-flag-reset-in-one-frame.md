# BUG-015 the entrance door 74,70,117 (building 16970) cannot be kept forbidden: the flag is reset within one frame, the lockdown still reports "doors 1 forbidden"
Status: open
Severity: high (the door lockdown of BUG-012 is recognised and commanded, but has no effect on the only existing entrance door; the report says it worked)
Found: 2026-10-15 17:06-17:12, test fort (copy of autosave 3, y372), dfpilot main 95fe16d, forced arrival popup
Module: `lua/dfllm/act.lua:984` (`door_forbid`), `lua/dfllm/reflex.lua:247` (lockdown doors); the reset itself comes from DF or another tool, not found yet

## Actual
```
ARRIVAL #11564 ... doors 1 forbidden, partial lockdown: stair_updown 55,62,117 has no door ...
commands.log   reflex act.door_forbid [16970,true] ok          (one call, no later [16970,false])
probe (2 s)    doors_forbidden=0/62 in every sample from the first one after the popup to the end
LOCKDOWN_END   ... 0 doors opened [doors=0]
```
Lua, by hand, three runs: `b = df.building.find(16970); b.door_flags.forbidden = true`, then read back with `dfhack.timeout(n,'frames',...)`:
`1:false 2:false 3:false 5:false 10:false 20:false 50:false` - the flag is false already one frame later.
Three other doors (ids 15683, 15690, 15744) set the same way keep `forbidden=true` for at least 6 s (probe: unchanged). A door built new
at the north opening (61,55,117) kept the flag for the whole lockdown on 2026-10-15 15:12 (probe `doors_forbidden=1/63`).

Door 16970: Door at (74,70,117), build stage 1/1, 0 jobs, 1 contained item (the DOOR item 1440066, not forbidden), `taken_by_invaders=false`,
`used_by_intruder=false`, `operated_by_mechanisms=false`; no citizen within 2 tiles. Pants and shoes (items 1495335, 1495341, 1495342) lie on the tile
(not forbidden, `in_building=false`). The DFHack `repeat` list holds only `control-panel/*`, `dfllm`, `combine` and `pop-control`; the kernel logs no un-forbid.

## Expected
`door_forbid` reads the flag back after a frame; when DF reset it the lockdown text says `door 16970 (74,70,117) refused (flag reset)`
instead of counting it, and the cause is found (tile content? a DF rule for doors on the route of the map edge? a script).

## Fix proposal
1. In `reflex`: verify the flag on the next pass (`already`/`mine` logic reads `door_flags.forbidden`; compare with `st.doors`) and report doors whose
   flag fell back as `partial lockdown` entries; try `closed` plus `forbidden` or a second attempt after the units on/next to the tile moved.
2. Find the resetter: compare 16970 with 15683 (same flags except position); suspects: the items lying on the door tile, the door's location at a
   stair mouth (z117 below the surface exit 75,70,118), DF clearing the flag of a door that is the only way for a unit inside.

Related: BUG-012, FR-49, FR-52
