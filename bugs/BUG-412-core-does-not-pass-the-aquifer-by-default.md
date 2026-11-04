# BUG-412 the core does not pass the aquifer: it is moved, shrunk or put on the surface instead
Status: fixed (offline, live-untested); open: the fortcore's own civilian stair crosses the layer in observe mode after the shaft passed; a heavy aquifer is not passed, only contained
Severity: critical (region1: no dug core for years; aqshaft 0 % for 176 days on i1 Inkintense)
Found: 2026-11-04, Gordon's decision: "ich moechte generell dass durch aquifier gegraben wird, so sicher wie moeglich. oberflaechenfort finde ich doof"; Run 15/16 `runs/run-1*/FR-BUGS.md`, main 503bb8b
Module: `lua/dfllm/aqshaft.lua`, `lua/dfllm/runner.lua` (aqx, rows), `dfpilot/plan.py` (aquifer_route, aquifer_core_swap, surface_facts), `dfpilot/bp/sites.py` (core_shaft)

## Actual
The fort belongs under the aquifer, but every path avoided it:
- `plan propose` (BUG-364) picked a shallower core, BUG-387/389 a surface core; the aqshaft was never drafted, only hinted
  (`aquifer_gate` warning). A shaft placed by hand failed live: BUG-191 (flooded level unnoticed), 193/194 (column/top), 291/292
  (no columns: `bp sites aqshaft` wants a public Z4 floor that a new fort lacks), 328 (i1 Inkintense: aqshaft `l0.dig 0 %` for 176
  days, quickfort refused, nothing said why), 359 (levels not rated), 365 (lost tile on an aquifer), heavy_aquifer breaches on every
  core site of region1 (BUG-364/387-389).
- No stall of the shaft was visible: an unreachable tile, no mason or no stone left the row at `queued`/`0 %`.

## Fix
### Draft (dfpilot/plan.py, bp/sites.py)
- `surface_facts` (the core cannot be dug / would cut a known aquifer level within 3 levels) now carries `aq = aquifer_route(...)`
  when `plan.surface_core` is off (BUG-413): the fortcore is ranked with `p.aquifer=pass` from the shallowest depth whose core level
  (Kern+, anchor z - 2 - depth) lies two levels under the shallowest known aquifer level (`d0 = anchor z - min(aquifer)`); the first
  ranked free site with a safe column wins. `sites.core_shaft` (bp/sites.py): the column stands beside the entrance (local u -3/+3,
  v 0..2: two tiles from the 3-wide entrance tunnel, so the shaft's 4 seal tiles never touch a fortcore tile), its top is open
  surface floor `.` in the citizens' walk group, the column and its 4 side tiles are rock or unknown on every level down to the
  core's deepest, no open water (`~ w %`) within 3 tiles on any of those levels, no cavern/warm level, no keep-out box; core levels
  meeting a known aquifer level or the level under it are refused ("a deeper core is needed"). `_shaft_clash` emits both documents and
  checks them with `Occupancy` (shaft against placed projects, then the core against the shaft): they neither overlap nor touch.
- `aquifer_core_swap`: the draft gets `aqshaft@S1 p{x,y,top,depth,dry_levels 2}` first (after a seal), then the fortcore stage 1 with
  `p.aquifer=pass`, `p.depth`, and the explicit anchor label `A<x>_<y>_<z>_<rot>` as its site (so ranking at apply time cannot choose
  a site other than the one the shaft was sited for); later fortcore stages get the same depth and stay at `same`. A shaft placed
  already is not drafted twice. No safe route (water, rock, walk group): the fortcore builds leave the draft with the reasons in the
  notes ("nothing is dug blind"), no surface core takes their place.

### Per-level method (lua/dfllm/aqshaft.lua) - the safest one dfpilot can do
Per aquifer level, light or heavy alike:
1. Only the shaft tile of one level is ever open. The next level is designated only when the level above has every side tile sealed
   (stone: all 4 orthogonal walls smoothed, soil: a plus shape dug and constructed walls on the 4 arms, read back from the tiles, not
   assumed) AND its flow was watched a game day (<= 1/7, or stable <= 3/7 and not rising for 3 days).
2. The seal is designated with the dig (the "pre-ring"): when the level looks like an aquifer before its tile is opened (a revealed
   `aq` flag on a side tile - the ring of the level below an open shaft tile is revealed -, a damp report, a known aquifer level, mode
   all) the dig of the centre and the smoothing of the 4 walls (soil: digging of the 4 arms) go out in ONE quickfort call, priority 1,
   damp marker. The miner who opens the tile finds the seal jobs waiting; before, they were designated only when a later runner pass
   saw the tile open, and a heavy aquifer fills a tile in that gap.
3. Plug reserve: below its top level the shaft designates nothing until the fort can make walls (`economy.mat_for wall`): CAVERN_PLUG
   and the soil walls need them. Missing stone/mason is a stall, not a gamble.
4. Water >= 4/7 or a rising flow in the shaft's own tiles stops it for good (`breach:heavy_aquifer`), plugs it (CAVERN_PLUG, constructed
   walls on the shaft's top tiles) and says AQ_HEAVY; the fortcore with `p.aquifer=pass` waits for a PASSED shaft
   (`Q.aq_wait`), so the 1-tile shaft is the probe: nothing wide is dug into an aquifer nobody has passed. Never a surface fallback.

Why this one and not another (what dfpilot can do with quickfort/constructions):
- The unavoidable exposure is the moment the level's shaft tile opens next to rough aquifer walls: smoothing or walling a tile needs a
  dwarf on an adjacent OPEN tile of the same level, and the only open tile there is the shaft tile itself (a ring tile dug first is
  exposed the same way, four times). So no "wall the ring first" is possible without exposing something; the pre-ring cuts the
  exposure to the time the miner needs, and a light aquifer (seepage 1/7 per many ticks) is sealed before it builds up.
- Cave-in/drop needs access to the layer from below or a channel across the layer, i.e. a wide open area in the aquifer: more
  exposure, and dfpilot's quickfort has no collapse control. Pumps/drains are not in fair play.
- A heavy layer therefore cannot be passed safely: it is contained (stop, plug, record the wet layer so `bp sites` keeps the next
  core off it). That is also why the shaft goes first.

### Stalls are visible (lua/dfllm/aqshaft.lua `stall`, runner rows)
`PROJECT_BLOCKED` (A) `why aq_stall:<cause>` once per level and cause, with `cmd`; the project row says `stall zN: <text>`:
`unreachable` (designated level for 3 days and `Q.unreachable`: `dfllm cmd bp.cancel proj=<id>; dfllm bp sites aqshaft --fresh;
dfllm cmd inspect '{"what":"reach"}'`), `no_stone` / `no_mason` (plug reserve or soil walls: `inspect workload`, `bp sites workshops
surface=1 --fresh` for Masons, a stone dig), `no_smoother` (smoothing nobody does). Cleared when the level moves on. No contract
change (existing event, existing `why`/`cmd` fields); `aqshaft.CFG.stall` (3 days), `pre_ring`, `plug_walls`.

## Tests
- `tests/lua/test_bug412_aqshaft_order.lua` (per-level order: pre-ring with the dig, one level open, next only after seal + watch;
  soil arms; the stalls no_stone/no_mason/no_smoother/unreachable, once, with the command, lifted); `test_aqshaft.lua` (two tests
  rewritten for the pre-ring).
- `tests/test_bug412_413_aquifer_default.py`: an aquifer world drafts aqshaft then fortcore aquifer=pass (applicable, no clash, validates);
  core level two under the aquifer; a placed shaft is not drafted twice; no safe column leaves the core out with the reason;
  `core_shaft` refusals (water within 3, non-rock side tile, other walk group, core meeting the aquifer).

## Open
- The fortcore's civilian stair (one tile column from the defense level to the refuge) crosses the same layers: it is dug after the
  shaft passed, in observe mode (damp marker, walls beside it smoothed), as FR-95 designed. A second pre-ringed pass for it is not done.
- Defense-level halls above the core that lie inside the aquifer (aquifer at surface-2) are dug in observe mode too.
- A heavy layer: contained, not passed.

## Live check
A region1 start fort (aquifer known): `dfllm plan propose` shows `aqshaft` then `fortcore` with `p.aquifer=pass` and a note naming the
levels; `plan apply` places both; `inspect` the shaft: `l0` a down stair, each aquifer level `pre 1`, `AQ_LEVEL_SEALED` then a day
until the next level; no `AQ_HEAVY`; `AQ_PASS_DONE`, then the fortcore stage 1 digs (AQ_OBSERVE src pass). With no mason the project row
reads `stall z.. : no mason builds the soil walls` and PROJECT_BLOCKED `aq_stall:no_mason` with its command.
