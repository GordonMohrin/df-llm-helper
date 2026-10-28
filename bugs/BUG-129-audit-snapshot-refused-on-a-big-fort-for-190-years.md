# BUG-129 The readiness audit never ran on the Run 14 fort: `audit snapshot refused: bbox 190x192x45 = 1641600 tiles > 400000`, audit_old/audit_fail held R0 for ~190 game years
Status: fixed in the BUG-129 commit (offline, live-untested)
Severity: high (no audit = no R1 for ever; readiness, drills and the pop cap stay frozen; the refusal's way out did not help)
Found: 2026-10-28, goal audit of Run 14 (region2-site90): ready.lvl 0, fail [audit_old, audit_fail, ...], audit age 75.9M ticks
Module: `lua/dfllm/snapshot.lua` (`regions`, `compose`, `refusal`), `lua/dfllm/runner.lua` (`boxes`, `keep_box`, `Q.tile_parts`),
`lua/dfllm/util/geom.lua` (`clusters`), `lua/dfllm/readiness.lua` (`cov_text`), `dfpilot/bp/topo.py` (`sources`); follow-up of BUG-043

## Actual
kern.log / state `ready.audit.why` on all three test copies of site90:
`bbox 190x192x45 = 1641600 tiles > 400000 at margin 0,0,0 (x 0-189 y 0-191 z 90-134; stretched most by seal c1a14d660b9fb1de01 (+2 more)
at z90: 948480 tiles less without them); file box 190x192x45 > 1500000; way out: bp.cancel c1a14d660b9fb1de01 if it can go, or raise
snapshot.max_tiles ...`. SIEGE_UNREADY counted audit_fail 432x and audit_old 411x.

## Cause
BUG-043 made the default audit box one box over all of the fort's pieces: the manifest geometry plus every `runner.boxes` entry (running
projects and the kept boxes of finished rooms, seals, plugs, repairs, explores); only explore shafts were column parts. The site90 manifest
geometry alone spans x 27-124, y 22-143, z 116-132 (203,252 tiles; 298,908 at margin 8,8,1: it fits). The runner's pieces did not:
three finished seals at z90 (26 levels below the core) and a piece over the whole map width (a seal's box is the bounding box of all its
walls, which can lie at opposite ends of the fort) made the one box 190x192x45. Kept boxes are never removed, so the box could only grow.
The way out was no way out: the stretching seals are finished, and `bp.cancel` refuses a done project (`... is already done`).

## Fix
- snapshot.lua `M.regions`: an audit box that fits at no margin as one box is exported as regions: the fort core (the manifest geometry) at
  the first margin step that keeps nothing out, plus every runner piece outside it as parts of its own (its tile clusters, else its box, each
  + `col_margin` 2,2,1), nearest to the core first. A piece whose parts break `max_tiles` (400,000, unchanged), `grid_max` (1,500,000) or
  `parts_max` (24) is dropped and named: reply/SNAPSHOT_READY `N regions, drops N far pieces: <first> (done; its tiles count as outside |
  bp.cancel <proj> if it can go)`, d `regions`/`drop`/`dropped`. Only the fort core alone over the cap is refused (`fort core WxHxD = ...`),
  naming its own stretcher. A finished piece is never offered to `bp.cancel` (also in the one-box refusal).
- runner.lua `boxes`: `parts` = the clusters of a project's tiles (`geom.clusters`, gap 6,6,1, at most 8) when they lie apart, for a running
  project from its stages and for a kept one from m.runner `kp` (stored with its box); `done` marks a kept box.
- Strictness: a tile no part read is the outside. bp.topo already starts attackers at a walkable tile beside one on its level; now also at a
  stair, ramp or cling that leads up or down to one, a ramp top over one and a walkable tile beside open space over one (a region box has
  unread levels above and below its parts, where one box over the fort would have read them). The file box's own faces stay as before. A
  dropped piece can therefore only add fails (a route from its unread tiles), never hide one, so readiness counts the audit (no coverage fail;
  `ready.audit.cov` `drop N: <piece>`). The pieces an explicit box leaves out still fail it (BUG-043).

## Tests (fail on dec5132)
tests/lua/test_bug129_audit_regions.lua (4: the site90 geometry with seals at z90, a map-wide kept box, a scattered seal, a dig beside the
core, a shaft; a dropped running piece names bp.cancel; the core over the cap is refused, a fort that fits stays one box; the file of a region
export), tests/lua/test_bug129_runner_parts.lua (2), tests/lua/test_readiness.lua (1), tests/test_bug129_audit_regions.py (3).

## Live check
On site90: `dfllm audit`; the reply says `margin 8,8,1, N regions[, drops N far pieces: ...]` instead of the refusal, `status` shows an audit
age of days, `ready.audit.cov` names a drop if any. If the audit then fails with a bypass from the core's bottom level, the route is real
in the worst case (a stair down to levels the export did not read): its wall closes it.
