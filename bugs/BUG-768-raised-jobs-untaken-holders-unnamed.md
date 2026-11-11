# BUG-768 Raised build and dig jobs stay untaken for 30-80 days: the busy holders were not named and nothing took them off their low-priority jobs
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y447-y449 (seal door 79,133,141 "job 970392 not suspended, no builder has taken it; all 31 holders busy (13 at Rest)" / "1 idle holder reaches it, DF did not assign it", 87 days, perimeter open); Run 16a i1 Basementflew y538 (seal y538s0b0 + explore y538s0b1 "dig 0%, 2 dig jobs open 0 taken" 30 days); Run 16d i4 Pagedsculpture (the explore miner at MakeCharcoal / HarvestPlants, runs of `bp.resume`).
Module: `lua/dfllm/economy.lua` (`T.boost`, `M.dedicate`, `M.hands`, `M.build_state`, `M.dig_wait`, `M.site_units`, `M.who_text`), `lua/dfllm/act.lua` (`labor_set` herb / burn / furniture)

## Actual
BUG-747 raises an untaken job to `do_now` after 3 days; DF never takes a dwarf off the job he is on, and a dwarf who holds many labors goes from charcoal to harvesting to the next hauling job for ever. The answers said "all 31 holders busy (13 at Rest)" or "2 idle holders reach it, DF did not assign it": no name, no labor, nothing to act on.

## Root cause
`economy.lua` `T.boost` stopped at the raise; `M.hands` counted holders by job type only (no unit, no id) and `build_state` never looked at who stands on the site tile (a builder does not start while a unit stands on it).

## Fix
- `M.dedicate` (from `T.boost`, PEACE / RECOVERY only, one change a day): a job raised 3 days ago (`M.DEDICATE.days`) and still untaken. (1) A building job whose labor (`M.BUILD_LABOR`: Furniture hauling, Mechanics) nobody holds: the labor goes on for one adult (`labor_set furniture` / `mechanic`). (2) A holder (Miners detail member for a dig, holder of the building's labor otherwise) who is at MakeCharcoal, HarvestPlants, PlantSeeds or GatherPlants while another citizen holds that labor too: that labor goes off for him (`labor_set burn` / `farm` / `herb`, `M.JOB_OFF`); his next job is the raised one. ORDER_STUCK (kind `worker`) and kern.log name the unit, its job and the labor. Once per unit; the last holder of a labor is never touched.
- `M.hands`: `busy_who` (up to 3: id, name, job) and `idle_who` (2); `build_state` appends ` [Name id at Job, ...]` to the all-busy answer and ` [Name id, ...]` to the idle-holders answer, and `M.site_units` names a living unit standing on the footprint (`rec.occupied`, `Name id stands on the site tile`). `dig_wait` names up to 2 busy Miners with their job.

## Open
Whether DF then hands the job to the unit is unmeasured; Rest and hauling holders are named, not changed (the kernel cannot tell a patient from a loiterer by the job alone); the labor stays off after the job is taken (other holders of the labor exist by the rule). Needs a Kernel reload. Nothing is raised or changed outside PEACE / RECOVERY, so no siege traffic case applies; no bridge, gate, refuge, lockdown or seal code changed.

## Tests
`tests/lua/test_bug768_untaken_jobs.lua` (5): miner at MakeCharcoal gets Wood burning off after the raise plus 3 days (not before, once per unit); the sole holder keeps the labor, a miner at Rest is left alone; nobody holds Furniture hauling -> labor on; build_state names busy and idle holders and the unit on the tile; dig_wait names the busy miner. The exact answers of tests/lua/test_bug747_749_boost.lua are updated for the names.
