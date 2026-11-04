# BUG-392 explore is drafted again at the spot where it already breached
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16b (i2 Ostgate, `runs/run-16b/FR-BUGS.md`: "plan propose schlaegt explore@(54,100,129) wieder vor")
Module: `dfpilot/bp/sites.py` (`_explore`, `failed_explores`, `_explore_redo`), `dfpilot/cmd.py` (`fort_manifest`, `_with_failed_explores`)

## Actual
y374 explore (57,100,129) stopped as breach:water (breach tile 60,100,123); y377 explore (54,100,129), 3 tiles away, stopped as breach:cavern_lake
(53,96,126); the y378-y380 drafts proposed (54,100,129) again (p.depth 2 / 12) and the player left the plans empty instead.

## Root cause
`sites._explore` avoided whole LEVELS only (`avoid_levels`: marks, `manifest.caverns`) and the shaft's depth; the breach record (`manifest.breaches`,
tpl explore, with the breach tile) was used by the fortcore ranking only (`_dry`, BUG-130). A shallower depth reaches no avoided level, so the same
anchor ranked first again; a water breach is not in `caverns` at all. Nothing remembered the anchor of a failed explore (the manifest record has the
breach tile, the anchor is only in the bp file).

## Fix
- sites.py `_explore_redo` (:1082): an anchor is skipped when a recorded breach (any template, `breach_points`) lies within `EXPLORE_REDO_R` (6)
  tiles x/y and in z az-depth-1..az+1 (the shaft and its arms), or when it lies within 6 tiles of a failed explore's anchor on its level +-1.
  When that leaves no site: ValueError "explore: every anchor lies within 6 tiles of a dig that already stopped (...); no safe explore site: trade for
  ore and bars, or open a new core level first" (plan propose/check show the reason instead of the same spot).
- cmd.py:259 `_with_failed_explores` (in `fort_manifest`): `manifest.failed_explore = [{anchor, why, proj}]` from the bp file of each explore breach.

## Tests
tests/test_bug390_392_reach.py (breach near the shaft with the shallow-depth exception, failed anchor on each depth, no safe site message,
fort_manifest names the anchor).

## Open
A bp file removed by cleanup loses the anchor; the breach tile still keeps the shaft's levels clear. Live: `plan propose` after an explore breach must
name another anchor or the "no safe explore site" line.
