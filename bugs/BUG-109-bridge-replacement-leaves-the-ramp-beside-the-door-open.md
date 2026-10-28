# BUG-109 A bridge replaced by wall + door leaves the way in beside it open: the stage list is the footprint's first row only, `seal` refuses the door tiles, R0 stays
Status: fixed in the M2 commit (offline, live-untested): after the wall + door stands, a second closure stage from the entrance check's own gap tiles (a ramp: a wall on its top, a floor: a door) until the route is closed
Severity: high (R0 `open_perimeter` for good; the pop cap frozen at the hold)
Found: 2026-10-24, Run 14 (Trussroads y636), game session note 76
Module: `lua/dfllm/seal.lua` (`KP.cells`, `KP.gaps`, `KP.extend`, `gates_pass`, `M.init`)

## Actual
Note 76: B1 was lost, the kernel replaced it by doors (121,67,131 and 121,69,131, both closed), yet the route stayed open: the ramp tiles
beside them (122,67,131 and 122,68,131) had no wall stage. `bp.place tpl=seal` refused both entries "left out, kernel still finds route open"
(dfpilot/cmd.py:888); R0 `open_perimeter` stayed.

## Cause (proven from the code at 32994bb; what stays open is under "Not decided offline")
1. **The stage list comes from the footprint alone.** `KP.cells(fp)` (seal.lua:1557-1568) returns the footprint's first row: walls on all
   of it but the middle tile, which gets the door. `gates_pass` (seal.lua:1681) calls the bridge replaced the moment those cells stand
   (`KP.standing(KP.cells(g.fp))` -> `KP.done`), whatever the entrance check says about the tiles beside them. `seal.lost_gates` (seal.lua:4813)
   and with it readiness' `lost:<B>` blocker end there too.
2. **The entrance check does know the way in.** Its exposure flood records the tiles each opening leads in by (`o.gap`, seal.lua:2410-2420) with
   their kind (`gap_kind`), and `M.entrance_doors` / `inspect refuge` `fix` list them (`19,25,9 ramp;20,25,10 floor` in the fixture). Nothing
   reads them for a bridge's closure.
3. **The Python seal cannot place it.** For an entry of kind door (`CLOSER_KINDS`) `geo.neighbour` returns None when the snapshot shows
   the door closing the doorway (cmd.py:872-889, "the door closes the doorway on the snapshot, the kernel still finds the route open"):
   the template never sees the ramp. That path is unchanged.
4. Reproduced by the fixture (tests/lua/test_m2_bridge.lua): the closure (wall, door, wall at x 20) stands, a ramp at 19,25 whose top leads
   along a corridor at z+1 over the wall line to a stair into the fort: the check says `open to 1 entrance 19,25,9 ramp +1 beside door
   20,25,9`, the old keeper says `replaced`.

## Fix
- `KP.extend` runs when the closure stands: it waits for an entrance check whose BFS and exposure flood are newer than the last change of a
  construction, door or bridge (`mem.fp_t`; it asks for one with `due('seal', 'refuge')`, once a day, for at most `ramp_wait` 3 days, then the
  bridge counts as replaced as before), reads the gap tiles within `ramp_near` (3) tiles of the footprint (z +-1) and queues what the seal
  template would build for them: a ramp gets `Cw` on its top (z+1), a floor tile a door (a tile with an unbuilt door, a stair or the like is
  left to the player). One `repair` project through the runner (`peace`, `closure`: walls first, doors next), at most `seal_max` (6) tiles.
- The bridge is **replaced at once, as before** (a siege that starts meanwhile sees a door, not a lost gate); the follow-up lives on the replaced
  entry (`rep[name].ex` {n, t, proj, cells}, `sd`, `sq`, persisted and validated at load; an old state without them works as before) and runs in
  the daily gates job in quiet PEACE. At most `ramp_rounds` (2) stages, a stage not built in 60 days is given up, kern.log says what stays open
  (`seal at=last` is then the player's); `inspect defense` shows `rebuild.follow` {n, proj, tiles}. A gap farther than `ramp_near` is not the
  closure's business. A sealed fort or a clean check: nothing is queued.

## Not decided offline
- **The live geometry of note 76.** The note's tiles (doors at 121,67,131 and 121,69,131, ramps at 122,67,131 and 122,68,131) do not match
  the manifest footprint it quotes (88,67,130-88,69,130) and `KP.cells` of a 1x3 footprint puts one door in the middle, so the kernel's
  gap list for those tiles cannot be rebuilt offline. Read-only live: `inspect entrances` (`openings[].gap`, `doors`, `state`), `inspect
  defense` (the bridge's `rebuild`), the SIEGE_UNREADY `ents`, and a snapshot of the 5x5 around 121,68,131 (`dfllm bp sites seal --fresh`).
- Whether DF lets a wall stand on the top of a ramp next to a door in the quickfort order of this stage (the template does it for `seal`).

## Tests
`tests/lua/test_m2_bridge.lua` (2: the ramp beside the closure: replaced at once as before, the second stage queued once, `inspect defense`
`follow`, a reload keeps it without queueing it again, the route closed when it stands, a sealed closure and a gap 20 tiles away left alone;
two rounds at most, then kern.log says what stays open). Both fail on 32994bb.
