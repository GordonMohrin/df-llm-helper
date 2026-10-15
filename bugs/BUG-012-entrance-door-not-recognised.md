# BUG-012 the arrival lockdown forbids 0 doors: "0 entrances", although the fort has a door at its entrance
Status: fixed in 4e2b43c (offline, live-untested)
Severity: high (the door lockdown never happens on a fort without a manifest; invaders are not steered away from the entrance)
Found: 2026-10-15 14:50, Run 9 save autosave 1 (y370), dfpilot main 3edc277, forced arrival popup (see BUG-011)
Module: `lua/dfllm/reflex.lua` (entrance doors), `lua/dfllm/seal.lua` (`entrances`)

## Actual
```
ARRIVAL siege (popup) "A vile force of darkness has arrived!..." -> clock 30 t/s, gates 4 wanted up (4 up, 0 pulls pending) X16032,X16033,X16034,X16035,
         doors 0 forbidden (0 entrances), alert on Kern+ ...
LOCKDOWN_END lockdown over (arrival:siege): threat 0 for 2 days; 0 doors opened
probe: doors_forbidden=0/62 in every sample
```
`inspect what=entrances` on the same save lists three openings of the fort, all with `"state":"no door"` (shaft head 55,62,118 stair_updown,
north ramp room 61,55,117 floor, east stair 75,70,117 stair_up). The Run 9 fort has a Door building at (74,70,117) one tile beyond the east stair, and
62 doors in total, but the audit does not treat it as an entrance door, so the reflex has nothing to forbid.

## Expected
The reflex forbids the doors that lie on the routes from the map edge to the citizens (the first door on each `entrances` route), or at least the doors
within N tiles of an opening; if there is none it says which openings stay open (shaft head, ramp room, east stair) so the operator knows the lockdown is partial.

## Fix proposal
Take the doors from the BFS route of `inspect what=entrances` (first door building on each route, including a door one or two tiles behind a stair), not
only from the manifest; list openings without a door in the LOCKDOWN text.

Related: BUG-011, FR-52, FR-54

## Cause
The reflex took its "entrance doors" only from a scan of door buildings next to a revealed open-sky tile on the same
level (`snapshot.outside_near` r 1). A door behind a stair or ramp opening has its open sky one level up, so none of
the Run 9 fort's 62 doors qualified; seal's entrance check knew the three openings but looked only at the opening tile
itself ("no door") and exposed no doors.

## Fix (4e2b43c, offline)
- seal's entrance BFS now lists the doors of each opening (`opening_doors`): a door on the opening's inside or outside
  tile, the first door on the BFS route from the opening toward the citizens (`B.par`, at most `CFG.door_route` = 12
  tiles, inside tiles only) and every door within `CFG.door_near` = 3 steps inside it (one walk from all its entries,
  following stairs and ramps, stopping at doors, `CFG.door_walk` tiles at most). Revealed tiles only (`rev`, the BFS's
  own walk-group answers). A bridge on the opening or on its route before any door marks it gated (the gates close it).
- `seal.entrance_doors(refresh)` exposes `{tick, sealed, routes, doors = {{id, pos}}, open = {{pos, kind}}}`;
  `refresh` queues an urgent check with a fresh BFS (`lockdown`). The reflex forbids those doors together with the
  open-sky ones at the lockdown's start and adds the doors of every later check while the lockdown holds (door_step).
  A door it forbade is never forbidden twice nor again after the player reopened it; a door the player forbade is
  counted ("were already") and never opened. The undo after quiet opens exactly `st.doors`.
- The text names the openings without a door or gate: `doors 1 forbidden, partial lockdown: stair_updown 55,62,117,
  floor 61,55,117 have no door` (two named, `+N` for more). `inspect entrances` ends with `N entrance doors, M openings
  without one` and has `doors` per opening and in all, plus `gate` per opening.
- Regression test `tests/lua/test_lockdown.lua`: a stair opening with its door one tile behind (forbidden, the shaft
  named as "has no door", the player's bedroom door left alone, LOCKDOWN_END opens exactly that door), a ramp opening
  with a door two tiles behind on the level below, a bridge-gated ramp, and a door behind a hidden tile never found.

## Live check (the same forced popup on the Run 9 save)
Before: `dfllm cmd inspect '{"what":"entrances","key":"refresh"}'`: the east stair 75,70,117 has the door 74,70,117
in `openings[].doors`; the message ends with `1 entrance door, 2 openings without one` (shaft head, ramp room) unless
those have doors within 3 steps. Inject the popup. Expected: ARRIVAL `... doors 1 forbidden, partial lockdown:
stair_updown 55,62,117, floor 61,55,117 have no door ...`; commands.log `reflex act.door_forbid [<id>,true] ok` for the
door at 74,70,117; the probe's `doors_forbidden` goes up by that many. After `dfllm ack` and 2 quiet days:
`LOCKDOWN_END ... N doors opened` with the same N, `[<id>,false]`, and `doors_forbidden` back to the old count.
