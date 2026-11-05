# BUG-429 plan propose never drafts the aqshaft for a core that stands, although the aquifer is known
Status: fixed (offline, live-untested); open: whether the observe-mode stage 3 digs through z123-129 behind a passed shaft (needs a live run)
Severity: critical (Gordon's top priority: forts go UNDER the aquifer; Glendagger had no refuge stage for 5 game years and nearly died of thirst)
Found: 2026-11-05, Run 16b i2 Glendagger y375-y378 (`runs/run-16b/FR-BUGS.md`, "propose schlaegt aqshaft nicht vor"), main 9e756ea
Module: `dfpilot/plan.py` (`surface_facts`, `aquifer_late`, `aquifer_late_swap`, `fortcore_stops`, `propose`), `dfpilot/bp/sites.py` (`surface_core_why`)

## Actual
`inspect water_sources` knew `aq:[124..129]`, the manifest `aquifer_levels` held z123-129, three fortcore stage-3 projects stopped on `breach:water` at
z129 (y374s2b1, y375s1b0, y377s1b0), and `plan propose` (y375, y377, y378) never drafted an aqshaft. The player placed `aqshaft@S1` by hand (`bp sites aqshaft
--fresh` had 12 sites); it started (l1.dig 5 %).

## Root cause
Not the aquifer sources: `sites.known_aquifer` already unions the manifest `aquifer_levels` (water_sources `aq` -> `runner.aq_seen`, damp reports), the
snapshot `aqz` and the breach layers; on a copy of the Glendagger runtime `aquifer_route` sees aquifers [123..129] and heavy [128, 127, 124]. The route was never reached:
1. `plan.py surface_facts` (the `any(t == "fortcore" ... applied)` early return): a fortcore stage 1+2 applied and `core` None returns `need False` before `aq`
   is computed. `core` was None because `core_breaches` only sees fortcore bp files that are not cancelled and not done: the player cancelled every stopped stage 3
   (`bp.cancel`), so the breaches vanished from `fort.core`.
2. Even with `core` set, the BUG-412 swap (`propose`, `aquifer_core_swap`) needs a NEW fortcore stage 1 in the draft (`not dug`, `any fortcore in builds`) and ranks
   a new core site (`aquifer_route`: "no dry fortcore site: every site's dig lies within 10 tiles of a recorded breach" in Glendagger): it is the route for a core
   that does not exist yet, not for the remaining stages of one that does.
3. `sites.surface_core_why` only counted a known aquifer within `SURFACE_AQ` (3) levels under the anchor, while a fortcore digs `SURFACE_DIG` (8): an aquifer 6
   levels under the anchor (Glendagger: anchor z137, refuge z129, aquifer z123-129) was no reason to leave the plain core site.

## Fix
- `aquifer_late(save_dir, applied)`: fortcore applied, no aqshaft applied, an aquifer known (`known_aquifer` + the levels two or more fortcore projects stopped on,
  `fortcore_stops`: manifest breach rows AND `BREACH_STOP` events of projects whose bp file, also a cancelled one, is a fortcore) and either such a stop or the core's
  levels (stage 1 anchor, depth, refuge) meeting a known level or the one under it -> `surface_facts.aq_late` = `{ok, why, aquifers, stops, meet, site}` with the first free
  `bp sites aqshaft` column.
- `aquifer_late_swap` (called by `propose`): `aqshaft@S1 p{x,y,top}` after a seal; every fortcore stage >= 2 build of the draft gets `p.aquifer = pass` (the runner's
  `Q.aq_wait` waits for the PASSED shaft, then digs in observe mode); the `BUG-429` note names the levels and stops. No free column: the note says so, nothing is added.
- `sites.surface_core_why`: a known aquifer level inside the whole dig range (`SURFACE_DIG`, or the site's dig box) sends a new core to the BUG-412 route too.
- No contract change (aqshaft and fortcore `p.aquifer` exist).

## Tests
`tests/test_bug429_431_aqprop.py`: the Glendagger case (breach rows, cancelled projects, events only, lone puddle stop, shaft already placed, core above the aquifer,
no free column), propose / place of the draft, `surface_core_why`. A scratch copy of the Glendagger runtime now drafts `aqshaft@S1 {140,108,132}` + `fortcore stage 3
aquifer=pass`; `plan check` 0 errors, `place_all` places both.

## Live check
A fort with fortcore 1-2 placed and a stage 3 stopped at breach:water: `dfllm plan propose` drafts `aqshaft` first and stage 3 with `aquifer pass`; after the shaft is
`PASSED` the stage digs ("breach:damp resumed in observe mode"). Open: a stage whose refuge level IS an aquifer level (z129) may still stop on water >= 4/7.
