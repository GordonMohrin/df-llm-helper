# BUG-399 depot 0 sites: the sites snapshot ends at the surface level
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3 Yawninggilt R2, `runs/run-16c/FR-BUGS.md`), main bb87afb
Module: `lua/dfllm/snapshot.lua`, `dfpilot/bp/sites.py`, `dfpilot/cmd.py`

## Actual
`bp sites depot`: `0 ranked`, also `--near 60,65,127 --within 60` 'no valid site' (no flat 5x5 surface block); DEPOT_MISSING every
year, no caravan ever unloaded (NO_DEPOT x2), seeds, metal and leather never came.

## Root cause
Not the terrain. The newest i3 sites snapshots (`snap/c1a1a7ec9380d2eb6a.json`, bbox z123-127) hold 8,366 floor tiles on z127; the
audit snapshot of the same fort has 293 flat 5x5 windows there. `lua/dfllm/snapshot.lua` `compose` builds the default sites box from
the fort's pieces plus margin `16,16,2`; the fort's core lay at z125, so the box ends at z127, the embark surface. `sites.py`
`_surface_shops` (and `_fortcore`) loop `for z in range(z0, z1)` and read the sky from row `z + 1`, so the top level, the surface
itself, is never evaluated. Replayed offline on the audit snapshot (z128 row present) the depot ranks at 72,66,128.

## Fix
- `snapshot.lua` `M.sites_up`: a `sites` export (default box) gets `M.CFG.sites_up` (3) more levels on top of the main box when the
  tile cap allows it (otherwise as before). Audit boxes are unchanged.
- `sites.py`: when a surface template (depot, startup shops, surface office or hospital) finds nothing and the snapshot's top level
  holds at least 25 floor tiles, the ValueError says so (`no level above it to show open sky (BUG-399 ...)`); the depot hint names
  the sky levels.

## Open
An explicit-bbox export still ends where its caller put it. A real lack of a flat 5x5 block (hills, forest) is still 'no valid site':
no levelling or ramp-removal variant yet (a depot on dug-flat floor would need a dig stage).

## Tests
tests/test_bug396_399_supply.py (2 for 399), tests/lua/test_snapshot_box.lua (sites box +3 levels, audit unchanged).

## Live check
i3-like: after `dfllm reload` a fresh `bp sites depot --fresh` lists sites on the z127/z128 surface; `bp.place tpl=depot site=S1`
queues the depot, the caravan unloads (TRADE).
