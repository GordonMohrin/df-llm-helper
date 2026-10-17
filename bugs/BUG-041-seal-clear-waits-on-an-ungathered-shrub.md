# BUG-041 seal.clear waits for good on a shrub nobody gathers; SEAL_STUCK stays in plan check for years
Status: fixed in <commit> (offline, live-untested): the seal template builds a shrub's piece on the shrub (no gather
stage); the runner skips the gather cell of a seal placed before the fix and removes its designation; SEAL_STUCK `wait`
names a clear job nobody has the labor for and a piece no citizen reaches; `plan check` names the reason and shortens a
seal stuck for a month to one line, a parked seal is no open seal
Severity: high (wrong decision: an open way in stays open for 220+ days; every new seal pauses the housing/work projects
for 3 days, then plan check warns for years)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y461 summer d45, kernel e8a28a6, from the game session's report and
its read-only live data
Module: `dfpilot/bp/defense.py:177, 326-332, 386-394` (the template), `lua/dfllm/runner.lua:479, 597, 642` (the measure),
`lua/dfllm/economy.lua:5015` (who gathers), `dfpilot/plan.py:362, 448` (plan check)

## Actual (live)
- kern.log: `seal first: c1a149cf2ff540c801 (seal) built nothing for 5 days at seal.clear: 1 piece open (door 59,62,146)`;
  `dfllm plan check`: `seal c1a149cf2ff540c801 (1 piece open) is stuck for 220 d (SEAL_STUCK): fix it first ...`.
- Earlier the same shape: the ramp head 79,116,146 in c1a147c261 (SEAL_STUCK after 196 d; the session cancelled it).
- Read-only (game session): the map is 192 x 192 x 165 (59,62 is no map edge); z146 is revealed, z145 hidden. Around
  59,62,146: y61 pebbles / floor / sapling, y62 shrub / **shrub (the piece)** / shrub, y63 floor / wall / floor; every
  tile but the wall on walk group 7827, the citizens' group. `inspect workload` showed 256-450 unclaimed GatherPlants
  jobs for years; food 700+ days.

## Cause (proved from the code at e8a28a6)
1. **The template gathers first.** `defense.seal_pieces` gives a `shrub` opening the piece `door` with `clear = "p"`
   (defense.py:332); `seal()` puts the `p` into stage `seal.clear` (#dig) and the door into `seal.plant` (387, 391). For an
   all-shrub seal `seal.build` is empty and dropped: the live document is `seal.clear p` then `seal.plant d`, which is
   what kern.log names. Behind it: the Run 11 y429 assumption "no piece stands on a plant" (CHANGELOG 2026-10-16), never
   checked against quickfort.
2. **The measure waits for the gather.** A `p` cell is no mine key; `probe` reads it as pending while snapshot.tile shows
   a designation (`designation.dig`) or a designation job on the tile (snapshot.lua:254, runner.lua:479); measure_dig
   completes a chunk only with no pending tile (642: the hidden-tile escape does not apply to a revealed shrub). So
   `seal.clear` waits until a dwarf with the Plant gathering labor does the GatherPlants job.
3. **Nobody gathers.** DF 53's plant gathering detail is off unless set; economy's gather task fills it only below
   `food.pre_days` (30) food days (economy.lua:5015, BUG-038); FR-25 marks shrubs only in a starvation. At 700+ food days
   the job stays unclaimed forever.
4. **quickfort never needed the gather.** DFHack 53.16-r2 `internal/quickfort/build.lua` (fetched from DFHack/scripts for
   this fix; byte-identical in 53.16-r1, 53.10-r2 and master): `is_valid_tile_generic` (49-58) accepts FLOOR, BOULDER,
   PEBBLES, TWIG, SAPLING and SHRUB; doors use `is_tile_generic_and_wall_adjacent` (178-185, key `d` at 760-761: generic
   plus a WALL/FORTIFICATION orthogonally beside it; 59,63,146 is a wall); constructions `is_valid_tile_construction`
   (151-166, set for every construction at 1087) via `is_valid_tile_has_space` (107-119, SHRUB and SAPLING included).
   The file's header says it enforces the in-game placement rules. `p` (`do_gather`, dig.lua:280-286) marks SHRUB tiles
   only.
5. **SEAL_STUCK for years.** After `seal_first.stuck_days` the seal stops pausing, but it stays open and stuck
   (sched.seal stuck 1); `seal_gate` printed the full `is stuck for N d ...: fix it first` at every check (plan.py:448),
   and `open_seals` counted a parked seal's bp file as open (plan.py:362: rows with `parked: ...` too).

59,62,146 is reachable (live data): the game session's first guess (a piece outside the citizens' walk group) was not
the cause here.

## Not decided offline
- **Does DF build the door on the shrub?** quickfort places it (the rule above); that the builder completes it and the
  shrub goes is the in-game rule quickfort mirrors, not seen live. Decides it: after the reload, the door at 59,62,146
  (`dfhack-run lua "print(dfhack.buildings.findAtTile(59,62,146))"` or the snapshot legend `+`), PROJECT_DONE of
  c1a149cf2ff540c801. If DF refuses: SEAL_STUCK at `seal.plant` with `build_lost` names it (then the old gather order
  with a plant gatherer is the fallback).
- **The ramp head 79,116,146 (c1a147c261).** Not reproduced: no live data. Decides it: its SEAL_STUCK event (`dfllm events
  --type SEAL_STUCK --limit 0`: stage, pieces, blocked, mat), kern.log lines of c1a147c261, and read-only
  `dfhack.maps.getWalkableGroup` of 79,116,146, its 8 neighbours on z146, 79,116,145 (the ramp) and 79,116,147, and of a
  citizen; the tile shapes there. The new `wait` says it at the next stuck seal (`no citizen reaches ...`).

## Fix
- **Template (`bp/defense.py`):** a shrub's piece (door, or the wall with `nodoor`, or the given piece) goes into
  `seal.build` on the shrub; `seal.clear` keeps only the chop (`t`) of tree tiles; the piece line says `door at 59,62,146
  on the shrub (quickfort builds on shrub tiles; no gather job)`. `GATHER_KINDS` is `SHRUB_KINDS`. Saplings keep the
  neighbour rule (it waits for nothing).
- **Runner (seals placed before the fix):** `Q.nogather` leaves a seal's `p` cells out of every dig apply and dry run;
  `Q.gathered` counts them done in the measure and removes a designation still flagged on the tile (quickfort #dig `x`,
  the designations screen's remove; a job DF posted without the flag is left, the plant goes with the piece); kern.log
  once per stage `<id> seal.clear: no gather at 59,62,146: the door goes on the shrub (...)[; its gather designation
  removed]`. The live seal then moves (`seal first: ... moves again`), pauses the others again until its door stands.
- **SEAL_STUCK `wait` (`Q.wait_why`, once per stuck event):** a clear stage's job and its labor (`FellTree at 57,62,146:
  Wood cutting enabled for 0 of 26 citizens: nobody takes it`); `no citizen reaches wall 100,100,146 or a tile beside it
  (walk groups 5018; citizens 7827)` when the piece's tile, its 8 neighbours, the tiles above and below are revealed
  (snapshot.groups) and none shares a citizen's walk group (tiles off the map are skipped; a hidden one is unknown: no
  claim). Informative only: no piece is dropped (a raised bridge, a ramp not dug yet may cut it off for now; flyers
  and climbers need no walk group). Also in the msg; wake hint.
- **plan check:** `open_seals` leaves out rows `parked: ...` and carries `why` (newest SEAL_STUCK: wait, mat, blocked,
  else its pieces); `seal_gate`: `... is stuck for 4 d (SEAL_STUCK: <why>): fix it first ...` below 28 days, then
  `... stuck 220 d (SEAL_STUCK, announced: <why>): temple run beside it`.
- Dropped (coordinator, after the live data): counting unreachable pieces as done. The walk-group test stays a report.

## Related
BUG-037 (a stuck seal yields its slot, parked projects), BUG-038 (the plant gatherers at food_low), seal first
(346c4ff), Run 11 y429 plants rule (276b252)
