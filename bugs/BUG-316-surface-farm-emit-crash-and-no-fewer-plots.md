# BUG-316 a surface farm crashes bp.emit; trees cut the 2-plot block and nothing falls back to fewer plots
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, live, right after BUG-297)
Module: `dfpilot/bp/emit.py` (emit), `dfpilot/bp/render.py` (as_built), `dfpilot/cmd.py` (place, fewer_plots, fewer_plots_sites, PLACE_NOTES), `dfpilot/cli.py` (bp sites), `dfpilot/plan.py` (farm_facts, food_draft, place_all)

## Actual
Inkintense y377, food 21 d: `bp sites farms plots=1 surface=1` ranked 2 sites (S1 92,87,133 rot1, 9 tiles from the entrance), but `dfllm cmd bp.place tpl=farms site=S1 plots=1 surface=1` and `plan check` with that build failed: `site S1: only 0 free site(s) ... ([92, 87, 133]: bp.emit(farms): min() iterable argument is empty)`. At the default plots=2 (and plots=4) `bp sites farms surface=1` ranked 0: trees ('T') stand in the soil floor by the entrance and cut every 11x7 / 11x15 block, and nothing tried fewer plots. plan propose's BUG-297 draft `farms@S1 p.surface=1` takes the default plots=2, which has no site there.

Root cause: `dfpilot/bp/emit.py:111` (9ef2ccb) put every room template (`rooms.BUILD`, not refuge-level) into Z4 by `dug_bbox(plan)`, the bbox of its dug tiles; the BUG-297 surface farm digs nothing, so `dug_bbox` (`emit.py:125`) took min() of an empty list. Every bp.place / plan check of a surface farm failed; BUG-297's tests ranked sites and built the template but never emitted it at a site. The preview (render.as_built) also put the plots on the synthetic rock world (`build p ... on '#'`).

## Fix
emit: a template joins Z4 only when it digs something (a surface farm opens no rock and is no fort core floor). render.as_built: a document set that digs nothing builds on the floor that stands, so the synthetic world gets floor (soil under plots) at its build cells. cmd.place: a surface farm (`farms p.surface`) at a ranked label S<k> that has no free site for its plots tries plots-1 .. 1 and places the largest that fits; `PLACE_NOTES[bp_id]` names it (`dfllm cmd` prints `note: BUG-316: no free surface farm site for plots=2 (...): placed plots=1`, cli.log `bp:note`, plan check's line ends with it); the document's params carry the plots placed. An explicit anchor (A<x>_<y>_<z>) or `same` never falls back. cli `bp sites farms surface=1`: no free site -> `BUG-316: fewer plots fit, plots=k` and those sites with the bp.place line at plots=k. plan.farm_facts: no free surface site at the default plots -> the largest fewer plots that has one (`fort.farms.plots`); food_draft drafts `farms@S1 p.surface=1 p.plots=k` and says so.

## Tests
`tests/test_bug316_surface_farm_emit.py` (5; the ranking guard passes on both, the other 4 fail on 9ef2ccb): emit at the live site 92,87,133 rot1, the preview without simulation errors, a z133 soil floor with trees and one 6x8 clearing by the entrance (plots=2 ranks 0, plots=1 ranks the clearing), place's fall back and its note, farm_facts/food_draft with plots=1 and the drafted build placed.

## Live check
Inkintense: `python -m dfpilot bp sites farms surface=1` prints `BUG-316: fewer plots fit, plots=1` and S1 92,87,133 rot1; `python -m dfpilot cmd bp.place tpl=farms site=S1 plots=1 surface=1` queues a 1-stage build project (no `min()` error), or with the default plots the line `note: BUG-316: ... placed plots=1`. Offline on a copy of the live save folder (snapshot c1a188bb847d268723): bp sites/preview/plan check as above, plan check `farms@S1 -> y377s0b3 at [92, 87, 133] rot1`; plan propose with the farms project done drafts `farms@S1 p.surface=1 p.plots=1`. Uncertain: one 5x7 plot is 35 tiles for 50 citizens, still too few; the kernel side of a project without a dig stage on the surface (runner) is BUG-297's and untested live.
