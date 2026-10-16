# BUG-032 A squad stationed next to B2 holds the BREACH raise: GATE_FAIL B2 'not up after 908 ticks'
Status: fixed (offline, live-untested): stations clear of every bridge footprint and its ring, the squad that holds a raise re-stationed, fortcore stations moved, validator check; part 2: O1's pull in the deep defense goes to a lever the confined civilians may take
Severity: high (wrong decision: our own station kept the core seal down in a BREACH; the gate rule that held it is right)
Found: 2026-10-16, Run 11 fort Kilrudrabed (site98), y432 spring, a cave dragon siege and a snatcher, then BREACH (0 deaths
so far), kernel of main up to 276b252, from the game session's events
Module: `lua/dfllm/military.lua` (station_of / apply_squad: BREACH's posture B2_HOLD takes `stations.b2` as it is),
`dfpilot/bp/fortcore.py` (`_manifest`: stage 3's `stations.b2` = local (1, 44, ze), one tile behind B2's footprint
(-1..1, 43, ze); stage 2's `stations.melee` = (0, 36, ze), two tiles from B1's (-1..1, 34, ze)), `lua/dfllm/gate.lua`
(squad_note: "stationed on the bridge" for a station on *or next to* the footprint)

## Actual
`GATE_FAIL B2: 'not up after 908 ticks'` (why `blocked`): squad 104 stationed at 115,116,142, the line said "stationed on the
bridge"; soldier 27836 held the raise. gate never raises onto a unit on or next to the footprint (BUG-027) unless a hostile
stands within `gate.force_near` of it, so B2, the core seal, stayed down for the BREACH.

## Expected
No squad station on a bridge footprint or its margin ring; a squad whose soldiers still hold a raise from their station
moves off at once, so the raise can happen. The forced raise (a hostile within force_near) stays as it is.

## Which code path picked 115,116,142 (best guess from the code)
The manifest, not a player's squad order:
1. In BREACH siege's posture table gives `B2_HOLD` (`siege.lua` POSTURE.BREACH); the mode change re-issues every squad's
   orders (`set_posture` -> `military.posture('B2_HOLD')` -> `apply_squad(force)`).
2. `station_of('B2_HOLD')` = `stations.b2 or stations.melee`; `stations.b2` comes from fortcore stage 3's manifest
   fragment, local (1, 44, ze) after the fort's anchor and rotation. B2's footprint is local (-1..1, 43, ze): the station
   is 1 tile from it, inside gate's MARGIN ring. gate's GATE/GATE_FAIL text said "stationed on the bridge" for any
   station within MARGIN (1) of the footprint, so "on the bridge" in the live line means on or next to it, which
   matches b2 at distance 1. (In SIEGE, READY_IN takes the same `stations.b2` while B2 is up or moving.)
3. A squad order the player set in the squads screen would survive military's re-asserts (apply_squad re-issues only on
   a new posture, a force or a lost order), but the BREACH posture change replaced every squad's order when the BREACH
   began, so it would have had to be given after that. Nothing points to it.
Check on the live save: `dfllm cmd inspect '{"what":"manifest"}'`: `stations.b2` = 115,116,142 confirms the manifest path.

Also: the Z4 landing between B2 and the civilians' stair is 5x3 tiles; it holds B2's margin row, its lever room
(`dfllm-levers-b2`) and the civilians' stair head. B2_HOLD stands *every* squad there: even a station on its far row puts a
crowd of 20-30 soldiers back into B2's ring. The old melee station (0, 36) had the same flaw for B1 (two tiles: DF stands a
squad's soldiers on the tiles around its station point, so its 3x3 reached B1's ring).

## Cause
- Neither military nor siege looked at the bridge footprints when they picked a station; fortcore placed `b2` (and
  `melee`) by hand, and the validator had no rule for stations. BUG-030 noted it as open ("a station at b2 stands next to
  B2's footprint and holds its raise") and added `stations.core`, but B2_HOLD and READY_IN still used `b2`.
- gate names the squad and its station (BUG-027), but nothing acted on it: "Soldiers are not moved off a bridge (a squad
  order is military's)".

## Fix (Claude, 2026-10-16)
1. **Stations clear of the bridges (military + `lua/dfllm/stations.lua`, a library):** wherever military picks a station
   (every posture: melee, gallery, b2, core, the intake field; siege's deep-defense core station via
   `military.station_for`; the sortie's gathering point via `military.safe_pos`) it must lie more than gate.MARGIN (1) +
   `stations.spread` (config/reflex.json, default 1: the squad's spread around its station point) tiles (Chebyshev, same
   z) from every manifest bridge footprint. Else it moves to the nearest revealed plain floor (snapshot.tile `.`, no
   building, off the manifest stairs, within 8 tiles; a hidden tile never counts) on the inner side of the footprints that
   hold it (the side with the deepest manifest zone: O1 -> Z1, B1 -> Z3, B2 -> Z4; without zones the side the station lay
   on, then away from the map edge); else the next station of the posture's chain (B2_HOLD: b2, then core, the core
   level's centre `z4`, then melee; READY_IN with B2 up the same; CORE: core, b2, z4, melee; melee chains: melee, b2,
   core, z4; the extra entries only after one failed, so a manifest without them keeps its stations). STATION_MOVED (B)
   `bridge` / `chain` / `none` and a kern.log line name the old and the new station, once per station and outcome.
2. **Re-station a squad that holds a raise (siege -> military.restation):** each siege pass reads `gate.holds()` (the
   bridges whose pull waits for units, with them); a soldier holding a raise who stands at his squad's station (within
   spread + 1 tiles of the station order, or the station itself within the clearance) gets his squad a new station at
   once (the squads screen's move order): the station moved on that bridge's inner side far enough that the squad's
   crowd stays out of the ring, else the posture's chain, then core, b2, z4. Squads military leads keep it for the
   posture (`rt.over`); a player's own squad gets the move order directly; a squad on a kill order or held for a sortie
   is left alone; a soldier only passing through (farther from his station) is not moved, the raise waits for him as
   before. STATION_MOVED `hold` (or `none`, at most every 2,400 ticks). The forced raise is unchanged.
3. **fortcore:** `stations.melee` (0, 38, ze), the gatehouse centre (4 tiles from B1, 5 from B2); `stations.b2` (-2, 45, zc),
   the core hub west of the civilians' stair (behind B2, with the drink; `core` stays the hub east of it). New forts only:
   a live manifest keeps its old values and rule 1 moves them in game.
4. **Validator** (`dfpilot/bp/validate.py`): `station_bridge` (error) for a station on a bridge footprint or within
   STATION_CLEAR (2) tiles of one on its level.
5. **gate's text:** `squad N stationed on the bridge at ...` (on it), `stationed next to the bridge` (within MARGIN),
   `stationed K tiles from the bridge` (the soldier stands at his station), `on its way to its station`.
- Contracts: event STATION_MOVED (B, military; schema, contract.lua, CONTRACTS §12 and the appendix), `gate.margin()`,
  `gate.holds()`, `military.restation/station_for/safe_pos` (§7), config `stations.spread` (§9.18; lint), manifest
  stations rule (§11).
- Tests (fail on 276b252): `tests/lua/test_stations.lua` (the library rules; Run 11 replay: BREACH with b2 one tile behind
  B2 -> the squads at the relocated tile, B2 rises, no GATE_FAIL; a hidden tile skipped; no floor -> core; a player's
  station next to B2 and a player's own squad re-stationed at once; a soldier passing over B2 not moved),
  `tests/bp/test_bp_stations.py` (fortcore stations clear in every rotation and stage, on plain floor, b2 on the core level;
  the validator rejects b2 at (1, 44, ze), melee at (0, 36, ze), a station on O1), `tests/test_alarm.py` (stations.spread).
  The shared test world's b2 moved from 51,62 (two tiles behind B2) to 51,63.

## Live check
After `git pull` and `dfhack-run dfllm reload` on Kilrudrabed: `dfllm cmd inspect '{"what":"manifest"}'` shows `stations.b2`
115,116,142 (question 4). At the next SIEGE/BREACH (or ALERT for melee): `dfllm events --type STATION_MOVED` and kern.log
`military: station b2 115,116,142 lies 1 tile from bridge B2 (clearance 2: gate margin 1 + spread 1): moved to ...` (and
`station melee ... lies 2 tiles from bridge B1 ...`); the squads screen shows the new station; with every squad on the
landing a `STATION_MOVED hold` (`squad 104 (A) holds the raise of B2: ... re-stationed at ... (core)`) and B2 up within the
pull latency; no `GATE_FAIL B2 ... blocked` naming a soldier at his station. If a squad is re-stationed again and again or
soldiers spread wider than 1 tile in 53.16, raise `stations.spread` in config/reflex.json (0-5) and note it here.

## Part 2: O1's pull in the deep defense (live y432 winter d64)
`GATE_FAIL O1 'no_worker'`: the kernel pulled lever 18664 several times without result, `lever pull --id 18664 --priority`
by hand was taken at once; the civilians stood confined in Tiefe+ (deep defense, SIEGE_DEEP, BUG-030).
- **Cause (from the code):** the lever burrow `Hebel+` joins the alert only while a pull is pending on a bridge none of whose
  linked levers lies in the alert's burrows. Fortcore stage 3 gives O1 a lever inside Tiefe+, so it was never listed;
  but outside BREACH gate's lever order put the Kern+ levers first (class "the burrow the alert holds the civilians in"
  meant Kern+ in every mode but BREACH), and nobody confined to Tiefe+ may take a job there. Each such pull waited
  NO_WORKER (200) ticks and was cancelled; the GATE_FAIL said `no_worker`, not `outside_alert`, because a linked lever
  (the refuge one) did lie inside the alert. The pull queued at T0 also went out before the alert sounded. (`act.pull`
  already queues with priority, like the hand pull.)
- **Fix (gate.lua):** the lever order's class 1 is the burrows of the sounding alert (siege's list; BREACH keeps the refuge
  first; a silent alert Kern+); a pull waiting without a worker on a lever outside the alert's burrows moves at once to a
  usable linked lever inside them (kern.log `... lies outside the alert burrows, a lever inside them instead`); `Hebel+`
  is listed also when every linked lever inside failed this epoch; wherever the alert confines to the refuge (BREACH, the
  deep defense, a lockdown that took Tiefe+) `Hebel+` follows breach_safe (no hostile in Kern+, none within 20 tiles of
  those levers), so no civilian is drawn out of the refuge toward a hostile.
- Tests (`tests/lua/test_gate_footprint.lua`): deep defense with O1/B1 levers only in Kern+ -> the alert lists `Hebel+`, a
  confined civilian pulls, no GATE_FAIL (passes on 276b252 as well: the case the session asked for); O1/B1 with a refuge
  lever -> the refuge lever pulls them within 300 ticks, no no-worker wait (fails on 276b252: two 200-tick waits on the
  Kern+ levers); a hostile 15 tiles from the Kern+ levers -> no `Hebel+`, GATE_FAIL `outside_alert` names Tiefe+ (fails on
  276b252: Hebel+ listed).
- Live check: in the next deep defense or BREACH, `dfllm events --type LEVER` shows the first O1 pull on the refuge lever
  (or on a lever of the alert's burrows); no `GATE_FAIL ... no_worker` with the civilians in Tiefe+; with a hostile near
  the Z3 levers a GATE_FAIL `outside_alert ... Tiefe+` instead of pulls nobody takes.

## Open
- Part 2 is a best guess: if `lever pull --priority` by hand is taken where the kernel's pull is not although the lever lies
  inside the alert's burrows, the difference is elsewhere (compare `dfllm events --type LEVER` with the hand pull's job).
- The re-station keeps a squad military leads at its new station until the posture changes; after the raise it does not
  go back to the landing (on purpose: the landing is B2's lever room and stair head).
- A fort without zones in its manifest has no inner side by zone: the station's own side, then away from `edge`.

Related: BUG-027 (footprint rule, the forced raise), BUG-029 (inner stations), BUG-030 (core station, the open point about
b2), Run 11
