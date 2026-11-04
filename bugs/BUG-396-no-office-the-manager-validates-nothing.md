# BUG-396 no office: the manager validates nothing, the brews wait for months
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16a (i1 Bachwald R2, `runs/run-16a/FR-BUGS.md`), main bb87afb
Module: `dfpilot/bp/rooms.py`, `dfpilot/bp/sites.py`, `dfpilot/plan.py`, `dfpilot/wake.py`, `lua/dfllm/economy.lua`, `lua/dfllm/runner.lua`

## Actual
i1 kern.log: `drink pre-alarm: 45 drink days (< 60): 7 brews wait for validation: no office (chair+table needed)` for 294 days
(18 orders, drink 0, ten dead); `manager office: no free office zone (the office template builds one ...)` every week, the only
DECISION_NEEDED `manager_office` (id 1008) once. The chair and table the bypass queued (MANAGER_BYPASS, day 592) had no office zone
to stand in.

## Root cause
- `lua/dfllm/economy.lua` `M.office_check` (no-zone branch): names the missing office and tries `office_zone` (a zone over a chair
  that already stands), but nothing builds one. The only builder is the `office` template, a room (`dfpilot/bp/rooms.py` `office`)
  that hangs on the dug public Z4 floor of a fortcore (`bp/sites.py` `rank`: `room sites need the fort manifest with zones.Z4`);
  i1 had no fortcore (breach:heavy_aquifer at 4 %, 0 sites). `plan.propose` never drafts an office in the no-core branch, and the
  DECISION text advised `bp.place office`, which fails there.

## Fix
- `rooms.office` with `surface=1` (`_surface_office`): a 3x3 block on open surface floor, the Office zone `assigned_unit=<role>` over it
  first (BUG-232), chair and table side by side (BUG-042), a manifest office room; nothing dug, no door, no burrow. `sites.rank` treats
  `office` + `surface` like the startup shops / hospital / depot (no manifest, flat open floor on the citizens' walk group,
  `_surface_shops`). `plan.build_kind` / `runner.lua kind_of`: a surface office is `supply` (no open seal pauses it: the manager
  validates the brews).
- `plan.office_facts` (`fort.office`: `have`, `site`) and `office_surface_due`: `propose` in the no-core branch drafts `office@S1
  p.surface=1` (note BUG-396) when no office stands, is planned or was applied and a surface site is free.
- Kernel `M.office_request` (from `office_check`, no Office zone for the manager, manager orders waiting, at most every 7 days):
  `PROJECT_REQUEST tpl=office why=office`; follow (`wake.py`) places it at prio 1 (surface variant without Z4) unless an office
  project exists. The DECISION text and `MANAGER_HINT` name `p.surface=1` and that follow places it.

## Open
The brew orders are still the manager's: until the office stands (chair and table built) nothing validates them; the kernel does not add
a direct still task (the BUG-231 bypass makes chair and table only). A fort with no flat open block has no site (BUG-399 widened the
sites snapshot, the block itself still needs flat floor).

## Tests
tests/test_bug396_399_supply.py (7 for 396), tests/lua/test_manager_bypass.lua (+1, one count narrowed to workshops requests).

## Live check
i1-like (no fortcore, no office): kern.log `manager office: none stands and N manager orders wait: an office is requested`, follow
places `office p.surface=1`, the 3x3 block gets an Office zone and chair+table, `status` `manager:` line clears,
`manager orders validated again`, brews run; `plan propose` notes `BUG-396`.
