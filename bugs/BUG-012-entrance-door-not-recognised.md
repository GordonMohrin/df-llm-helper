# BUG-012 the arrival lockdown forbids 0 doors: "0 entrances", although the fort has a door at its entrance
Status: fixed in 4e2b43c, 0faebcc (offline, live-untested)
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

## Follow-up (0faebcc, offline): nobody locked out, the perimeter after an ambush
- Citizens shut out: a door is forbidden only once no citizen (soldiers excluded, as for the gates) is on its outside
  side: `seal.door_outside(ids)` counts those on a revealed open-sky tile of the door's walk group, on the porch of an
  opening it closes (the inside between the opening and its doors: the near-door walk goes on past `door_near`, still
  stopping at doors, `door_walk` tiles at most, for openings that have a door) and in the doorway; without seal,
  sense's citizens outside Kern+ hold every door. Exceptions: a visible hostile within `reflex.DOOR_NEAR` (15) of the
  door forbids it at once; `ALERT_AFTER` (450) ticks after the lockdown first wanted the doors every door is forbidden.
  The waiting doors are looked at every `DOOR_POLL` (20) ticks; the civ alert calls the citizens in meanwhile (where
  gates are pending it waits for them, so the woodcutter may only be called at the deadline: see the live check).
  Text: `doors 0 forbidden, 1 waiting for 2 citizens outside, partial lockdown: ...`; state `alarm.doors/dwait/dout`,
  and `dfllm status` prints `doors 1 forbidden, 1 waiting for 2 citizens outside` after `lockdown <why>`.
- Perimeter after an ambush: seal opens a perimeter episode (`pre`: pieces already gone are retired) when the fort
  leaves quiet (ALERT, SIEGE, BREACH, RECOVERY or a reflex lockdown in any mode) and diffs it (`post`: lost pieces
  re-queued, PERIMETER_BROKEN) once it is quiet again (PEACE without a lockdown), level-triggered in every step and mode
  change; before, only SIEGE/BREACH opened one and only RECOVERY/SIEGE_END diffed. The PEACE retire pass waits while
  an episode is open.
- Tests: `test_lockdown.lua` (a citizen on the field at the trigger: the door waits, still waits while he stands on
  the stair, is forbidden within a poll once he is in the hall; a goblin 5 tiles from the door forbids it at once; a
  citizen who stays out holds it 450 ticks), `test_seal.lua` (a wall lost in ALERT and one lost during a lockdown in
  PEACE are re-queued once with PERIMETER_BROKEN; a wall removed in peace before the lockdown is retired, never
  rebuilt), `test_cli_status.py`.

## Live check (the same forced popup on the Run 9 save)
Before: `dfllm cmd inspect '{"what":"entrances","key":"refresh"}'`: the east stair 75,70,117 has the door 74,70,117
in `openings[].doors`; the message ends with `1 entrance door, 2 openings without one` (shaft head, ramp room) unless
those have doors within 3 steps. Inject the popup. Expected: ARRIVAL `... doors 1 forbidden, partial lockdown:
stair_updown 55,62,117, floor 61,55,117 have no door ...`; commands.log `reflex act.door_forbid [<id>,true] ok` for the
door at 74,70,117; the probe's `doors_forbidden` goes up by that many. After `dfllm ack` and 2 quiet days:
`LOCKDOWN_END ... N doors opened` with the same N, `[<id>,false]`, and `doors_forbidden` back to the old count.

Citizens outside: inject the popup while a woodcutter works on the surface near the east stair (or send one out with a
job there). Expected: ARRIVAL `doors 0 forbidden, 1 waiting for 1 citizen outside`, `dfllm status` the same after
`lockdown arrival:siege`, no `act.door_forbid` for 74,70,117 while he is out; within ~1 s game time after he passed the
door (or at the latest 450 ticks after the popup) `reflex: 1 more entrance doors forbidden` in kern.log and the
`[<id>,true]` line in commands.log; `status` drops the "waiting" part. With the four gates pending, the civ alert sounds
only when they are up or at 450 ticks: watch whether he walks in before the doors close (if not, report it).

Perimeter: after the lockdown (and after any ALERT episode), kern.log `seal: quiet again: perimeter diff after the
episode`; on the Run 9 save the destroyed shaft-head wall, once recorded (`dfllm cmd perimeter.record '{}'` while it
stands), comes back as PERIMETER_BROKEN with a `rp...` repair project when it is lost during an ambush.
