# BUG-415 propose redrafts the running core, drafts P5 with no core to build, and `bp sites fortcore --fresh` times out
Status: fixed (offline, live-untested)
Severity: high (Run 16c i3 Yawninggilt: the player edited the draft by hand every year; no sites export for the player to rank on)
Found: 2026-11-05, `runs/run-16c/FR-BUGS.md` (y388 Fruehling, y391 Fruehling, "OBS Fix-Runde 22"), main b4087f4
Module: `dfpilot/plan.py` (core_resite, propose, no_core_route), `dfpilot/cmd.py` (sites_box, fresh_wait, wait_snapshot), `dfpilot/cli.py`

## Actual
1. y388: stage 3 `y387s2b2` parked at `breach:water`, stage 1 `y387s2b0` was still digging (4 %, "set aside, no runner slot"). `plan propose`
   drafted `fortcore@S1` stage 1, 2 and 3 again; `plan check` refused it ("y387s2b0 is the fort's fortcore already ... cancel first",
   `cmd.py _place` BUG-358). The player cancelled stage 3, resumed stage 1 and took fortcore out of the plan.
2. y391: no fortcore, no free fortcore site, no way through the aquifer (aquifer_route not ok): the draft's target was P5 and the check
   refused it ("no refuge burrow ... add fortcore stage 3"); the player set P2 every year.
3. `bp sites fortcore --fresh`: "no snapshot ... within 60s" after round 22.

## Root causes
1. `plan.core_resite` (was plan.py:1758) put EVERY fortcore project on an anchor named by a breach row into the "stopped" set: the
   breach row of stage 3 (anchor A) made the live stage 1 on A look like part of the parked core (`at`), `moved` stayed None (the
   moved-core test only looks at anchors NOT in the breach set), `resite` was true (no stage 1 dug), `core_movable` true, so
   `propose` drafted `CORE_RESITE` (fortcore@S1 stage 1) plus `@same` for the stopped anchor's stages {1,3} and the phase's stage 2.
2. `propose` lowers the target below the refuge phase only for a parked core that cannot move (`core["resite"]`), never for a fort
   with no core at all whose route is closed (surface_facts.need with aq not ok, or the surface core without a site). The builds were
   left out (BUG-412 `aquifer_core_swap`) but `phase_target` stayed at P5 and `refuge_gate` refused it.
3. The sites export of a fortcore (`cmd.sites_box`) is up to CORE_TILES = 300000 tiles; round 22 made the export read more per tile (ice,
   mud, the open-sky level above for BUG-399, walk groups), and a box that did not fit round all pieces fell back to the kernel's own
   default box (up to snapshot.max_tiles 400000). The CLI waits `--timeout` = 60 s flat.

## Fix
1. `core_resite`: a stage 1 on a breach anchor that is itself neither stopped nor done is the running core (`live`, the current core
   first); it is reported as `moved` (the existing "re-sited already: never a second stage 1" path), its own running later stages are
   not to cancel, the stages that stopped on its anchor are `moved.stuck` and not drafted there again; the note says so
   (BUG-415) and `core_gate` warns with it. Only the stopped stage is in `ids` (what to cancel). A stopped stage 1 still re-sites
   (BUG-130 unchanged).
2. `plan.no_core_route(fort, state, done)`: no fortcore project applied/drafted, no refuge burrow, `surface.need`, and no route
   (`aq.ok` false with surface core off, no surface-core site with it on): `propose` holds `phase_target` below `REFUGE_PHASE` (never
   below the current phase) and the notes say `BUG-415: phase_target P5 -> P2 ... the target rises once a core is placed`.
3. `CORE_TILES` 150000; a box that fits round no pad is a square round the median of the pieces (side from the tile budget, at least
   `CORE_BOX_MIN` 90), never the kernel's default box; `cmd.fresh_wait(box, timeout)` = max(timeout, 30 s + tiles / 1500 per s), at most
   300 s, printed ("N tiles requested, waiting up to T s"); `wait_snapshot(progress=)` prints "waiting for snapshot ... 15s of 83s"
   every 15 s; the timeout message says the export may still finish.

## Tests
`tests/test_bug414_415_heavy_core.py`: a stage 3 stopped on the anchor of a running stage 1 drafts no `fortcore@S1` and no stage 3 there,
the note and `plan check` agree; a stopped stage 1 still re-sites; no core and no route holds the target below P3 (check has no
"no refuge" error); a route or a standing core keeps it; `fresh_wait`, `box_tiles`, progress callback. `tests/test_bug364_367_aquifer_core.py`
(far-flung fort: bounded box round the median instead of None).

## Open
- A stage that stopped on the running core's anchor is not redrafted anywhere: the player takes it back and decides (the next site
  or a decision); `propose` does not move it.
- The pace constant (1500 tiles/s) is a guess; the live check below sets it.

## Live check
i3-like: stage 1 digging, a later stage parked: `plan propose` shows no `fortcore@S1`, the note names the running core; no fortcore, no
route: `phase_target` stays at P2 with the BUG-415 note; `bp sites fortcore --fresh` prints the tile count and the wait and
finishes (or says the export may still finish); a kern.log SNAPSHOT_READY with the time tells the real pace.
