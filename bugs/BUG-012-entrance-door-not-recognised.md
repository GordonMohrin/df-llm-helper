# BUG-012 the arrival lockdown forbids 0 doors: "0 entrances", although the fort has a door at its entrance
Status: open
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

## Retest 677bc3e (15:12)
After building a Door at the north opening (61,55,117) and `perimeter.record`, the arrival lockdown says `doors 1 forbidden (1 entr...`, probe `doors_forbidden=1/63`, `LOCKDOWN_END ... 1 doors opened`. So the reflex works on the recorded perimeter piece. Still open: the fort's other two openings (shaft head 55,62,117 stair_updown, east stair 75,70,117) have no door and the existing Door at (74,70,117) is not recognised as the east entrance door (`inspect entrances`: `state no door`).
