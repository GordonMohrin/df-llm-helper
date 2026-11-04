# BUG-375 the perimeter opens again every year (saplings in the openings) and holds the pop cap beside a queued seal
Status: fixed (offline, live-untested): a sapling gets its piece on the sapling; the open-perimeter freeze waits while a seal project is live
Severity: medium
Found: 2026-11-04, Run 16d (i4 Plankscale, y374-y380, 79 days open, pop capped at 38), `runs/run-16d/FR-BUGS.md`
Module: `dfpilot/cmd.py` (seal_openings), `lua/dfllm/readiness.lua` (phold)

## Actual
i4: SIEGE_UNREADY names a new floor/sapling/shrub way in after almost every season (events n=725, 818, 926, 1038, 1133,
1236, 1401, 1494 ...: one to five tiles, `perimeter OPEN 2 d` again and again; `perimeter OPEN 105 d (5 ways in)` at n=1494).
Each seal (c1a1a6dda..., c1a1a6f02..., c1a1a70b7...) closed the listed tiles, the next saplings grew elsewhere. max-pop
stayed at the population (FR-70 hold) while a seal project was already queued.

## Root cause
- `cmd.py seal_openings`: a sapling went to the neighbour that closes its route (`9,3,0 floor for=9,2,0:sapling`); the plant
  stays, and a regrown plant in the 1-wide mouth counts as a new way in; BUG-323/333 put the piece on the sapling only as a
  fallback (no neighbour closes it, tile off the snapshot).
- `readiness.lua` (freeze, `st.phold`): set from `perimeter.escalate_days` on whether or not a seal project is already on its
  way, and kept until the whole perimeter is closed. With a new opening every season the spell (st.pt) never ended.

## Fix
- A sapling's piece always goes on the sapling tile (read as floor; quickfort builds doors and walls on SAPLING tiles,
  build.lua is_valid_tile_generic), snapshot or not; shrubs already did (BUG-041). `door_stands` still turns a door into a
  wall where no wall stands beside it.
- readiness: while `runner.pending('seal')` > 0 the freeze is neither set nor kept (`rt.sealq`); it applies again when no seal
  project is live. R0 `open_perimeter` and the days stay.
Reading of 'the pop cap must not drop': the cap is not pinned to the population while the push (a seal) is on its way.

## Open
Where the saplings come from (tree crowns read as roof by `des.outside`, BUG-323) needs a live look; nothing here stops new
saplings, it closes each tile durably once and lifts the cap hold meanwhile.

## Tests
tests/lua/test_bug375_hold_seal_queued.lua (2, fail on 2fcd6e0), tests/test_bug374_376_seal_audit.py (1),
tests/bp/test_bp_seal_run11.py and test_bug333_sapling_off_snapshot.py (adjusted to the piece on the sapling).

## Live check
Next sapling way in: `seal at=last` queues `x,y,z floor` with the note `the piece goes on the sapling itself`; the status pop
hold is gone while `seal open: N pieces` is listed.
