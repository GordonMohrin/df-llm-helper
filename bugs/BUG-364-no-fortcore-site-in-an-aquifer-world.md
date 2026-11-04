# BUG-364 no fortcore site in a world with an aquifer almost everywhere (depth 1 refused, no shallower core offered)
Status: partly fixed (offline, live-untested): a core of depth 1-2 is a valid template depth, `bp sites`, `bp.place` and `plan propose` fall back to it; open: a core fully above an aquifer that starts 2 levels under the surface
Severity: critical (a new fort stays without a core for years)
Found: 2026-11-04, Run 16a-d (i1 Bachwald, i2 Ostgate, i3 Yawninggilt, `runs/run-16*/FR-BUGS.md`), main 2fcd6e0
Module: `dfpilot/bp/fortcore.py`, `dfpilot/cmd.py` (shallower_core, shallower_core_sites, place), `dfpilot/cli.py`, `dfpilot/plan.py` (fit_core_depth)

## Actual
The world region1 has an aquifer nearly everywhere (the players scanned ~180 sites). i1: surface z110, aquifer z105/107/108,
the default core (depth 3, refuge 3) digs from z108 to z101 and cuts it; `bp sites fortcore aquifer=above`, `depth=2` and
`--near` answered 0 ranked, `depth=1` was refused (`fortcore.depth: expected an integer 2..12`). i3: heavy_aquifer at
A74_92_125_3, cavern_lake at A88_92_125_3, dig_lost at A106_78_125_1. Nothing offered a shallower core, and the draft never
chose one.

## Root cause
- `fortcore.py:40` `PARAMS["depth"] = (3, 2, 12)`: the shallowest core was the defense level + 2 (whole fort 8-9 levels under the
  surface). The geometry has no reason for the minimum 2 (a core one level under the defense level validates for all 4 rotations).
- Nothing tried another depth: `sites.rank` ranks one depth, `cmd.place` / `plan.propose` took the default.
- `sites.py:1241` `_flooded` only penalizes the known aquifer levels per site (250 each); the player sees `aquifer at z..` and
  has to guess the depth to try.
- Not the cause (checked on i1's data): the manifest's aquifer_levels filter nothing without `p.aquifer`; the `0 ranked` of
  i1/i2 is BUG-366 (sites box).

## Fix
- `PARAMS["depth"] = (3, 1, 12)`: depth 1 (core directly under the defense level, the refuge 3 levels below it: the fort ends at
  surface-6 instead of surface-8) is valid.
- cmd.py `shallower_core` / `shallower_core_sites`: for a stage 1 fortcore (no retrofit, no `p.aquifer`) the depths below the asked
  one (2, 1); `bp sites fortcore` prints a "shallower core (BUG-364): depth=N" block when nothing is ranked or every ranked site
  passes a known aquifer level, with the place command; `place()` at a ranked label falls back to depth 2, 1 when the asked depth
  has no free site (PLACE_NOTES line, cli.log); `plan propose` / the automatic plan (`plan.fit_core_depth`) give a NEW stage 1
  and the new later stages of the draft the shallower `p.depth`.
- cmd.py `core_params_of`: a later stage (>= 2) placed at the anchor of an earlier fortcore stage (`site=same` or an explicit
  anchor) takes its depth/refuge from that stage's bp file, so `fortcore@same st2..4` of a depth-1 core are not emitted for
  depth 3 (the plan's later stages carry no depth param).

## Open
A core completely above an aquifer whose top level lies 2 below the surface does not exist (defense level = surface-2); there
the aquifer is crossed shallow in observe mode (`p.aquifer=pass` after an aqshaft) or the fort lives on the surface workshops
(BUG-356). Rooms on the levels above the first damp layer without a core: not done.

## Tests
tests/test_bug364_367_aquifer_core.py (depth 1 validates, fallbacks, depth inheritance, draft depth); tests/bp golden unchanged.

## Live check
i1/i2/i3-like: `bp sites fortcore --fresh` in an aquifer world lists `shallower core (BUG-364): depth=1/2` sites when depth 3
meets the aquifer; `bp.place fortcore site=S1 depth=1`, then the stages at `site=same` build at depth 1 (`inspect manifest`
refuge anchor = surface-2-1-3).
