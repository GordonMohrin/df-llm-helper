# BUG-679 A project's "no builder has taken it" / "suspended by DF" gives no reason (cut at 80 characters), 2 idle adults add no runner slot
Status: fixed (offline, live-untested)
Severity: medium (projects set aside for months with the cause unreadable; idle hands unused)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y444-y456 (kern.log:871-872, 461; FR-BUGS 'Projekte set aside, no runner slot rotieren ohne Fortschritt'): `rp183648611 (repair) stalled 53 d ... waits: Door 65,121,141: job 1191999 not suspended, no builder has taken it: outside the: set aside`, `depot5 ... waits: TradeDepot 82,76,139: job 1192077 suspended by DF (not buildingplan, not suspend: set aside`; a Cook and a Dyer idle while one project held a slot
Module: `lua/dfllm/economy.lua` (`M.build_state`), `lua/dfllm/runner.lua` (`Q.parts`, `Q.idle_scan`, `Q.stall_scan`, `Q.slot_cap`)

## Actual
- The reason was in the line, at its end: `economy.build_state` words it 'job N not suspended, no builder has taken it: outside the burrow ... / walled in ... / no free adult citizen has the labor ...' and 'job N suspended by DF (not buildingplan, not suspendmanager): <bits>'. `Q.parts` cut it at 120 characters and `Q.idle_scan` / `Q.stall_scan` at 80 and 80: the PROJECT_BLOCKED text ended at 'outside the' and '(not buildingplan, not suspend', the cause never reached the player.
- 'suspended by DF ... no cause readable' (depot4 32 d, depot5 53 d): only citizens on the site were looked for. The same fort's stuck merchants of the last caravan stood at 84,77,139 / 84,76,139, on the depot's footprint (kern.log:621, 'caravan Muboomon still listed Leaving ... units at 84,77,139 84,76,139').
- `Q.slot_cap` added `free // slots_idle` slots (3): two free idle adults (the Cook and the Dyer) were 0 extra slots.

## Root cause
`economy.lua` build_state (`rec.line`): the cause came last behind 40-60 characters of boilerplate; `runner.lua` `Q.parts` / `Q.idle_scan` / `Q.stall_scan` truncate. DF branch: `rec.units` counted `K.census.u.ids` (citizens) only. `runner.lua` `Q.slot_cap`: floor division.

## Fix
- `build_state` also answers `short`: the cause first, no job id: 'no builder: outside the burrow X (civil alert on); walled in on its level; no free adult citizen has the labor ...' / 'no builder has taken it (no cause readable)' / 'suspended by DF: <bits>' / the buildingplan and suspendmanager lines without the job id. `Q.parts` uses `short` (140 characters); the waits in the set-aside, stalled and stale events keep 110 (were 80).
- The DF branch counts every creature of any kind on the site that is not a citizen (merchant, invader, animal, other): '2 other creature(s) on the site now (2 merchant): DF suspends a construction a creature stands on'; `rec.foreign`.
- `Q.slot_cap` rounds the idle adults up: `(free + slots_idle - 1) // slots_idle`, so one free idle adult is one slot more (never above `slots_max`).

## Tests
`tests/lua/test_economy_build_state.lua` (BUG-679 x2: `short` of a job nobody took, of a DF suspension, of buildingplan; a merchant on the site named), `tests/lua/test_bug486_slots_moods.lua` (BUG-679: 2 and 1 free idle adults of 39 are 4 slots).

## Live check
`PROJECT_BLOCKED` of a set-aside or stalled project: `parts` / `waits:` starts with the cause ('no builder: outside the burrow ...'). A depot 'suspended by DF' while merchants stand on it names them. A fort with 2 idle adults runs 4 projects at once.

## Open
- A door 'outside the burrow' (assigned burrows, civil alert) is named, not fixed: letting the builders out of their burrow is the player's decision (the kernel keeps the citizens in Kern+ in a siege).
- A depot job DF suspends with no creature, no item and no cancel report is still 'no cause readable' (the daily resume goes on); the runner does not move the manifest depot.
- A set-aside project still comes back only by progress or `bp.resume`; the extra slot only helps projects that are not set aside.
Related: BUG-328, BUG-329, BUG-486, BUG-444
