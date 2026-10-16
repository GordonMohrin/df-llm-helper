# BUG-015 the entrance door 74,70,117 (building 16970) cannot be kept forbidden: the flag is reset within one frame, the lockdown still reports "doors 1 forbidden"
Status: fixed (offline, live-untested); the resetter itself is not found yet (see Possible causes)
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

## Possible causes (not confirmed; to check live)
1. **Items on the door tile.** Pants and shoes (1495335, 1495341, 1495342) lie on 74,70,117, not in the building. DF cannot close a door
   with an item in the doorway; it may also drop the lock of a door that cannot close. The three doors that kept the flag had nothing on
   their tiles (to be confirmed). Check: mark the clothes for dumping (a player action), wait until they are gone, set the flag again.
2. **The door at a stair mouth.** 74,70,117 is one tile behind the up stair 75,70,117 under the surface exit 75,70,118, on the only route
   between the surface and the fort. DF may unlock a door that is the only way out for a unit that must leave or enter (a merchant,
   visitor or diplomat with a leave-map goal, a unit inside whose path runs through it).
3. **A unit in or on the way through the doorway** (a hauler en route, a pet), although no citizen was within 2 tiles in the probe.
4. **Another tool.** The DFHack `repeat` list held only `control-panel/*`, `dfllm`, `combine` and `pop-control`; none of them writes door
   flags as far as known, and the kernel logs no un-forbid. Less likely.

## Fix (Claude, 2026-10-16)
The resetter is still unknown; the kernel no longer believes a lock it does not have.
- `lua/dfllm/reflex.lua`: every door the lockdown forbids is recorded as not read back yet (`m.reflex.vfy`) and read back on the next
  reflex pass (10 ticks later; DF reset the flag within one frame). A door whose flag held counts. A door whose flag fell back leaves
  `st.doors` (the `doors N forbidden` count, the status and the undo), is kept as refused (`m.reflex.ref`, with the units on or next to
  its tile and the items on it) and named as a partial lockdown entry:
  `doors 0 forbidden, partial lockdown: door 16970 (74,70,117) refused (flag reset), stair_updown 55,62,117 has no door`.
- New event **LOCKDOWN_PARTIAL (A, reflex)** on the refusal: `partial lockdown: door 16970 (74,70,117) refused (flag reset; 3 items,
  0 units on or next to its tile), one retry (forbidden + closed) once that changes (<= 1200 ticks), doors 0 held`, d `doors` (held),
  `refused` (ids), `pos`, `retry`, `items`, `units`. Cadence: the first refusal of a lockdown at once, a new door or a failed retry again
  only after max(7 days, 10 min) (a failed retry within that is a kern.log warning); the next lockdown is a new episode.
  The ARRIVAL text is still written in the step the doors are commanded, so it counts them as forbidden; LOCKDOWN_PARTIAL follows
  10 ticks later.
- **One retry** per door and lockdown, when the visible units on or next to the door tile or the items on it changed
  (`snapshot.units_at`, new, and `snapshot.items_at`; revealed tiles only), at the latest `DOOR_RETRY` = 1,200 ticks after the refusal,
  with the usual safety (citizens outside, hostiles near). The retry also sets `door_flags.closed` (new optional `close` argument of
  `act.door_forbid`) when nobody stands in the doorway. Held on the retry: the refusal ends; fell back again: refused for this lockdown.
- **LOCKDOWN_END** counts only doors whose flag the kernel holds (`; 1 doors opened`) and names the refused ones
  (`; 0 doors opened, 1 refused (flag reset)`, d `refused`); a refused door is never "opened". State `alarm.dref`, brief
  `doors 0 forbidden, 1 refused (flag reset)`.
- Tests: `tests/lua/test_lockdown.lua` (door 19,10 behind the stair with DF's reset modelled on the door: items on the tile, retry
  after they left; a door that never holds: exactly two tries, LOCKDOWN_END `0 doors opened, 1 refused`, cadence, new episode; a visitor
  in the doorway: the retry once he stepped aside, closed), `tests/lua/test_kern_act.lua` (`door_forbid` with `close`). The three
  lockdown cases fail on the old code (no LOCKDOWN_PARTIAL, no retry, `0 doors opened` only).
- Live check: on a copy of the test fort (y372) force the arrival popup; expect LOCKDOWN_PARTIAL for 16970 with `3 items` and
  `inspect`/status `dref 1`; then mark the clothes on 74,70,117 for dumping by hand and watch kern.log for `held on the retry` (cause 1)
  or `refused ... try 2` (then check cause 2 with a door built one tile further inside).
