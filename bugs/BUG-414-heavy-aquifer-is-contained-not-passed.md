# BUG-414 a heavy aquifer is contained, not passed: no core under it
Status: fixed (offline, live-untested); open: a heavy layer thicker than one level is stopped before its second level, not passed; the ring's mechanics (channel + wall from above) have never run in DF
Severity: critical (Run 16c i3 Yawninggilt: heavy aquifer at all three core sites, no core after 20 years; Run 16d i4, Run 16b i2 the same worlds)
Found: 2026-11-05, Gordon: "generell durch den Aquifer graben, so sicher wie moeglich"; `runs/run-16c/FR-BUGS.md` (y387-y393), main b4087f4
Module: `lua/dfllm/aqshaft.lua` (ring_level, ring_step, ring_leak, ring_stacked), `lua/dfllm/runner.lua` (heavy_known, hv_level, breach), `dfpilot/bp/aquifer.py` (param heavy), `dfpilot/plan.py` (heavy_levels, aquifer_core_swap note)

## Actual
BUG-412 passes light aquifers level by level but CONTAINS a heavy one: water >= 4/7 or rising in the shaft's own tiles stops it for
good (`breach:heavy_aquifer`), plugs it and records the wet level so `bp sites` keeps the core off it (`lua/dfllm/aqshaft.lua`
`heavy`, before this change). i3 met heavy water at three core sites (c1a1a797 103,20,120; y387s2b0 76,34,127; a third), so it had
no core, no refuge and no hospital for 20 years. The probe itself is the problem: the miner who opens the shaft tile of a heavy
level stands in a tile that fills at once.

## What DF allows (evaluated, documented here; nothing of it could be run offline)
Facts the repo already stands on (aqshaft.lua header, DECISIONS 2026-10-28, DFHack 53.16 docs): water comes from a natural ROUGH
wall with the aquifer flag into the open tiles orthogonally beside it and the open tile below it; a smoothed wall is no source, a
constructed wall never is; quickfort's dig (`h` channel, `j/i` stairs, `s` smooth) and build (`Cw` constructed wall) are the only
tools; no pumps, no `digv`, no reveal. The cavern plug (`runner.plug`, Run 11, live: the 136,73,137 shaft) already channels a stair
tile and builds a constructed wall on it from the tile above, the lower wall first, "reached through the upper one" - so building
a wall on a tile of the level below from a dwarf standing in the shaft above is a method this code base has used in the game.

1. Cave-in / drop: needs a wide hole in the aquifer layer (support removal, `channel` across a floor) and quickfort/DFHack have no
   collapse control (cave-ins are DF's own, unordered). More open aquifer surface, more exposure. Rejected.
2. Wall ring from above (chosen): the 4 side tiles of the heavy level are never touched by a miner standing in that level. Per
   side tile, one at a time: channel the tile on the dry level above (`h`, damp marker, priority 1; the dwarf stands on the shaft's
   stair tile beside it), DF leaves an open ramp in the heavy level below; build a constructed wall on that ramp (`Cw`) from the stair
   tile. Only when all 4 stand is the shaft tile of the heavy level dug, so it touches no rough aquifer wall at its sides.
3. Pump stack: not fair play, not available. Rejected.
4. Constructed wall on a damp tile (DF 50): the wall is not an aquifer, but the tile must be open first (the exposure in 2).

Why 2 is the safest dfpilot can do: the only exposure is an OPEN RAMP tile that nobody stands in (the builder works from the dry
level above), one at a time, watched; the BUG-412 method instead opens the shaft tile with a miner in it. The limits, said plainly:
- The open ramp is open to the heavy wall on three sides and the tile above it (the channelled ring top) is open air beside the
  shaft's stair tile: if the ramp fills and the water climbs, the dry level above gets wet. The ring watches the shaft tile and every
  channelled ring top for any water (`ring_leak`): water there = AQ_HEAVY + plug (CAVERN_PLUG walls the shaft's top two tiles).
- A ring wall designated but not standing after `ring_wait` (2 days) or refused 3 times: the same stop and plug.
- A channel quickfort refuses 3 times: `apply_fail` (nothing is open, nothing to plug).
- The ring tiles of the next level lie under the constructed walls of this ring (a wall cannot be channelled): a layer thicker than
  one level cannot be ringed twice. A level KNOWN to be heavy under a ringed one stops the shaft BEFORE it is opened (AQ_HEAVY why
  `stacked`, nothing open); a level only suspected (neighbour of a recorded one) keeps the BUG-412 method with its heavy stop.
  So a heavy layer of ONE level is passed, a thicker one is contained at its second level with the shaft standing sealed above.

## Fix
`lua/dfllm/aqshaft.lua`
- `A.ring_level` (a level below the top is ringed when `X.heavy_known(z, heavy_span 1)` or p.heavy = all; `p.heavy = off` keeps
  BUG-412), `A.ring_step` (dig_step calls it before the level's dig: per side tile `new` -> `chan` (channel designated on z+1) ->
  `open` (the tile above is dug and the ramp shows) -> `wall` (`Cw` designated) -> `done` (the tile reads `C`); one tile at a
  time; the plug reserve (4 + 2 walls, `plug_missing`) first, the stall causes `no_stone`/`no_mason` and the new `ring_dig`
  (nobody channels, or `unreachable`)), `ring_leak`, `ring_stacked`. A ringed level counts as an aquifer level (`aquifer_here`),
  its dug tile is sealed at once (AQ_LEVEL_SEALED how `ring` n 4), watched a day and passed like any other. The runner slot is held
  while a ring is open (`A.holds`), the leak check also runs in measure-only passes.
- `heavy()` records the level (`X.hv`).
`lua/dfllm/runner.lua`: `Q.hv_level` (m.runner `hvl`, <= 32 z), `Q.heavy_known(z, span)` (hvl and the breach records `dz` with
why heavy_aquifer, a fortcore that stopped on one counts), recorded at every `breach(..., 'heavy_aquifer')` and by the shaft.
`dfpilot/bp/aquifer.py`: param `heavy` = ring | all | off (default ring; validated). `dfpilot/plan.py`: `heavy_levels(manifest)`,
`aquifer_route` returns `heavy`, the aquifer draft's note names the ring for the recorded heavy levels.
No new events, no new contract field: AQ_HEAVY `why` gains `ring_leak | ring_late | ring_refused | stacked`, PROJECT_BLOCKED
`why` gains `aq_stall:ring_dig` (CONTRACTS rows updated).

## Tests
`tests/lua/test_bug414_heavy_ring.lua` (10): full ring cycle (one tile at a time, the shaft tile only after all 4 walls, AQ_LEVEL_SEALED
ring/4), unknown level keeps BUG-412, `heavy=off`, `heavy=all`, leak above, wall not built in time, refused channel, ring_dig
stall once with the command, thick layer stops before opening (stacked), a heavy stop records its level and the next shaft rings it.
`tests/test_bug414_415_heavy_core.py`: the param, `heavy_levels`, the draft note. `tests/bp/test_bp_aqshaft.py` and the golden:
`heavy: ring` in the params.

## Open
- The mechanics have not run in DF 53: (a) does quickfort `Cw` accept the ramp a channel leaves (`is_valid_tile_construction`)?
  (b) can the dwarf on the stair tile reach and build on a diagonal-below ramp (the plug builds straight down)? (c) how fast does a
  heavy ramp tile fill and does water climb through the open ring top? If (a) or (b) fails the wall is refused (3 times) or never
  built (2 days) and the shaft stops and plugs: the same containment as before, no worse.
- A heavy layer thicker than one level is not passed.
- p.heavy = all rings every level below the top (slow, 4 walls a level) for a world the embark panel called heavy.

## Live check
A fort whose manifest breaches name a heavy level (`inspect manifest`, `breaches` why heavy_aquifer): `plan propose` drafts aqshaft
with the BUG-414 note; `inspect` the shaft: `l<k>` with `ring`, the four pieces going `chan` -> `open` -> `wall` -> `done`, a `h` on
the level above, a `Cw` on the heavy level, one at a time, then the shaft tile `i`; kern.log `z.. is a heavy aquifer level`; no
AQ_HEAVY. Watch the first ring tile: if AQ_HEAVY `ring_leak`/`ring_late`/`ring_refused` comes, the CAVERN_PLUG row says the shaft is
walled and `bugs/BUG-414` Open (a)-(c) is the reason.
