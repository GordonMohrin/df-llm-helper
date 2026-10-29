# BUG-300 the runner's phase stays P0 for years: a deliverable that can never be made holds it
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15 round 3 (Drillchamber, Inkintense; runs/run-15d-drillchamber/FR-BUGS.md 'Runde 2'/'Runde 3')
Module: `lua/dfllm/runner.lua` (CHECK.proj, check_phase, phases, verb phase.waive), `dfpilot/wake.py` (follow `_place`)

## Actual
Drillchamber y372-y378: `state.phase` P0 the whole run while every plan targeted P5 (`plan.json` phase_target P5); the
trap lanes (P5), gear/kit and the cavern sweep (P6) and the large rooms (P7) never unlocked (FR-BUGS 'Runde 3':
"Plan bleibt P0", "P7 nicht erreichbar"). Of the P0 deliverables of `plans/year1.json` (baseline, fortcore 1, office,
farms, workshops Still+Butchers) only `farms` failed: no farms project exists any more (both were lost to `build_lost
missing p` on stone, `plots need soil or mud ... lost for good`, and cancelled), and `bp sites farms --fresh` ranks 0 sites
(reproduced on a copy of the runtime: `plan.farm_facts` -> site `none`, 0 room and 0 surface sites). Follow's PLAN_EXHAUSTED
starter and economy's farms requests ended in `AUTO_FAIL farms: site S1: only 0 free site(s) for farms` again and again.
Inkintense y372-y376: P0 too, with one farm plot standing on the map: its project c1a18745d4e25dac02 is `parked:
build_lost` at 40 %, so `proj_reached(farms)` never became true. Earthboat (farms built) reached P5; Guildcleans sits at P1
for missing moodable shops (a deliverable that can be built; not this bug).

Root cause: runner.lua:3741 (`CHECK.proj`) passes only through a project of ours that reached the stage, never through a
farm plot that stands, and runner.lua:3781-3806 (`check_phase`/`phases`) has no way to drop a deliverable that cannot be
made: one impossible deliverable holds every later phase for ever.

## Fix
- `CHECK.proj` for `farms` (no stage) is also met by a built farm plot on the map (`Q.farm_plots`, FARM_PLOT buildings).
- Waivers: persist `phase.waive` = `{d, why, ph, t, by}` (<= 8). A waived deliverable no longer holds the phase. Sources:
  the new verb `phase.waive {tpl, why, stage?}` (runner; refused for a deliverable not of the current phase - the reply
  lists its keys -, one met already, and while a live project of that template runs: `bp.cancel it first`), and the
  kernel's own rule: every farms project lost to build_lost with its retries spent (`M.lost`) and none live (parked)
  -> `N farms project(s) lost to build_lost: plots need soil or mud`. kern.log `phase P0: farms cannot be made (...):
  waived, the phase goes on without it`. The verb re-runs the phase check, the reply names the new phase.
- follow: when a farms placement fails with `only 0 free site(s) for farms`, the current phase delivers farms and the
  sites snapshot has neither a farms room site nor a surface site (`plan.farm_site` `none`), it sends `phase.waive
  {"tpl":"farms","why":"bp sites farms: 0 room and 0 surface sites"}` (once per hour), cli.log `auto:waive`.
- Contracts: verb `phase.waive`, persist.phase `waive`, RULES section 6 bp.place row (in place).

## Tests
`tests/lua/test_bug300_phase_waive.lua` (7), `tests/test_bug300_302_phase.py` (contracts, follow). All fail on 9ef2ccb.

## Live check
Drillchamber after the load: within a few minutes of a PLAN_EXHAUSTED or a farms request, cli.log `follow auto:waive
... deliverable farms of P0 waived`, kern.log `phase P0: farms cannot be made (bp sites farms: 0 room and 0 surface
sites, by follow): waived`, then PHASE events P0 -> P1 ... up to P5 (the plan's target; P6/P7 need approval).
Inkintense: PHASE P0 -> P1 at the next runner run (the farm plot meets farms). If the phase stays: `dfllm status` line
`phase P0: waits for ...` names the next deliverable (BUG-301). Uncertain: whether the later phases of Drillchamber then
pass at once (P3 hospital and the P4 trade were reached by projects of Run 15; any other one shows in the status line).
