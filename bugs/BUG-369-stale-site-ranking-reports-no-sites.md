# BUG-369 a stale site ranking reports 0 sites until --fresh
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16d (i4 y372) and Run 16b (i2 y373), main 2fcd6e0
Module: `dfpilot/cmd.py`, `dfpilot/cli.py`, `dfpilot/plan.py`

## Actual
i4: `bp sites workshops` -> 0 ranked, only `--fresh` found 6 sites; the year plan P5 contained no workshops (Carpenters, Farmer,
Clothier, Loom missing, 16 orders stuck, beds 'waits for bed'). i2: `bp.place workshops only=Bowyers` briefly '0 free sites'.

## Root cause
`cmd.sites_snapshot` takes the newest sites snapshot file; rankings (`.sites-<tpl>.json` cache, keyed on the snapshot id) are
made on it whatever has been dug or built since. Nothing compared the snapshot with the projects' progress: a snapshot taken
before the core's dig (no Z4 floor) ranks every room template 0, and `plan propose/check/apply` and `bp.place` all rank on it.
Only the player's `--fresh` asked for a new export (`cli.py run_bp`).

## Fix
- `cmd.snapshot_stale(save, snap)`: no snapshot, not a sites export (no `wg`, no `aqz`), or a PROJECT_STAGE / PROJECT_DONE event
  newer than the snapshot's tick (a dig or build stage finished after it). `cmd.auto_refresh` sends `snapshot purpose=sites`
  and waits (25 s) when the kernel's heartbeat is fresh (120 s); otherwise it sends nothing and the output says so.
- `bp sites <tpl>` without `--fresh`: refreshes a stale snapshot first, and asks once more when the ranking is empty
  (`snapshot refreshed (nothing ranked on the cached snapshot)`); `plan propose|check|apply` refresh a stale snapshot first;
  `cmd bp.place` that fails with `only N free site(s)` refreshes once (stale or not) and places again on the new snapshot.
- A refresh that cannot be done is a note (`snapshot may predate the map (...); not refreshed`), never an error.

## Open
The rankings made inside the kernel-less Python (`follow`'s auto plan) still use the newest snapshot file; `follow` itself
requests snapshots on its own cadence. The staleness test is event-based: map changes without a project (a collapse, a
flood) are not seen; `--fresh` stays for that.

## Tests
tests/test_bug368_370_depot_fresh_walk.py (stale detection, refresh on `bp sites`, current snapshot left alone, empty ranking asks
again, silent kernel sends nothing, `bp.place` refresh and retry).

## Live check
i4 after a core stage: `bp sites workshops` (no --fresh) prints `snapshot refreshed (PROJECT_STAGE ...)` and lists sites; `plan
propose` then drafts workshops; `bp.place workshops only=Bowyers` after a stage no longer says '0 free sites'.
