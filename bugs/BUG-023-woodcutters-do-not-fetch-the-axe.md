# BUG-023 woodcutters in the Woodcutters detail never take FellTree jobs: the two axes lie in a bin in a stockpile and nobody fetches one
Status: mitigated in 47d98c4 (offline, live-untested): detection, TOOL_BLOCKED (A), labor repair, miners out of everybody details; the pickup trigger `tools.equip_update` is off until Gordon says yes
Severity: high (no logs for a game year: no furniture, no barrels, no brewing, mood deaths, 81 buildings waiting)
Found: 2026-10-15 21:20-22:10, Run 10 fort Handlelock (region2-site97, y366-368), dfpilot main 95fe16d + local trade fix
Module: `lua/dfllm/economy.lua` (builtin tool details `Woodcutters`, `tools` axe count), `act.work_detail`

## Actual
```
kern.log   labor: 58 of 58 starving postings are stale (oldest Fell Tree, 15860 ticks)
workload   unclaimed FellTree 19 (flags dessource,do_now), cancels: Needs logs (x many), no FellTree cancel ever
Woodcutters detail: 2 units (20104, 22973), mode OnlySelected, CUTWOOD labor true, no burrow, all trees reachable (canWalkBetween true for 19/19)
tools {axe 2, axe_free 2}: both are ITEM_WEAPON_AXE_BATTLE inside a BIN in a stockpile at 102,124,122, flags in_inventory, not forbidden
dfhack.job.addWorker(FellTree job, woodcutter) -> the job is dropped within seconds (no axe)
```
Months of `Needs logs` cancellations: wooden bin, chest, charcoal, crutch, barrels (no empty barrel -> `Brew drink from plant: Needs empty food storage item`, drink 193 -> 107 days),
81 planned buildings `waiting for materials`, Possessed mood dwarf 25877 died with 0 logs attached.

## Workaround (confirmed live)
`dfhack.items.moveToInventory(axe, woodcutter, df.inv_item_role_type.Weapon, -1)` for both woodcutters: within 40 s the first FellTree job started, `logs` went 55 -> 284 -> 309 (237 reachable and free),
idle fell from 85 % to 44 %, the stalled building projects moved again.

## Expected
The kernel notices a FellTree backlog older than a few days with idle woodcutters and axes in storage, equips an axe to each woodcutter (a new `act.equip_tool`) or says `FELL_BLOCKED: no woodcutter holds an axe`.

## Fix proposal
In economy's `Woodcutters` (and `Miners` with picks): after `act.work_detail` check `u.inventory` for an axe (pick); when a member holds none and `tools.axe_free > 0`, move one into its weapon slot. Report the starving-postings reason (`no axe in hand`).

Related: BUG-022, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md` (wood supply and moods)

## Fix (Claude, 2026-10-16)
Not implemented on purpose: the live workaround `dfhack.items.moveToInventory` (it moves an item into a unit: RULES §1.1,
no UI does that). It stays out of the kernel, also behind a config switch; using it needs Gordon's explicit yes for that
fort and is then a game-session action, not kernel code.

What the kernel does now (`lua/dfllm/economy.lua` tool details, `lua/dfllm/act.lua` `work_detail`):
- **Detection, `TOOL_BLOCKED` (A, util/cadence):** a Miners or Woodcutters member holds no pick/axe (unit inventory, any
  mode but hauled) for `tools.block_days` (3) while the detail's dig/FellTree jobs wait unclaimed and free tools exist. The
  event names the members (ids, first names), the free tools and where they lie (`bins` in a container, `loose`, `reserved`
  by a squad uniform via `plotinfo.equipment.items_assigned`, the position of the first one) and the causes the kernel
  repaired (`labor`, `everybody`). Repeats only for a new member or cause. `inspect workload` has `blocked` and
  `tools.{pick,axe}_{free,bin,res}`.
- **Starving postings reason:** the labor line reads `labor: 58 of 58 starving postings are stale (oldest Fell Tree, 15860
  ticks: no axe in hand (Woodcutters 2 of 2))` while the detail is blocked.
- **Labor repair:** a member without the detail's labor (`MINE`, `CUTWOOD`, `HUNT`, `FISH`) gets it through
  `act.work_detail` (Run 10: members written into `assigned_units` by Lua had no MINE labor), at most every `repair_days`.
- **Miners as specialists:** a miner leaves every everybody-does-this detail that is no tool detail (Planters in mode 1
  pulled six of eight miners to the farms) and its labors go off, except `keep_labors` (FEED_WATER_CIVILIANS,
  RECOVER_WOUNDED) and labors of a selected detail the unit is in (`act.work_detail` opts `only`).
- **The player's members stay:** only members economy added itself (persist `m.economy.tools[name].mine`) are ever taken
  off; the others count toward the target and make no WORK_DETAIL. Hunters and fishers still all leave when the fort
  leaves PEACE.
- **Tool cap:** a detail never gets more members than free unreserved tools plus the tools its members hold; when it
  shrinks, members holding the tool stay first.
- **Equipment update [live-untested, off]:** `tools.equip_update = true` makes `act.work_detail` set the dwarf's
  `uniform.pickup_flags.update` and `plotinfo.equipment.update.weapon` when it switches a tool labor on. That is the request
  the engine hands work picks and axes out on (v1 E18 Run 5: without the per-dwarf flag non-squad miners never got a work
  pick); the dwarf still walks to the tool himself. It is a write to a unit field, so v1 kept it in the exception register
  (FP08): switch it on only with Gordon's yes.

Remedies considered and not built, with the v1 evidence (the v1 repo's `ERFAHRUNGEN.md`, E18 Run 3 and Run 5, and its `lua/claude/pickfix.lua`):
- **Loose storage (`max_bins 0`, a weapon pile without bins):** v1 Run 3 emptied the bin and set `storage.max_bins=0`
  without effect, and Run 5 measured that tools in a bin are handed out. Bins are not the cause.
- **The E18 squad trick (a squad whose uniform is only the pick/axe):** v1 Run 5 found it makes things worse: a pick
  uniform spec reserves free picks per squad position, reserved picks are never handed out as work tools, and soldiers
  lose MINE/CUTWOOD/HUNT when they join. The kernel instead reports reserved tools (`reserved`) so the military's weapon
  choice can be changed.

Live check: `inspect workload` (`blocked`, `tools`), kern.log `labor: ... no axe in hand`, a TOOL_BLOCKED wake with the bin
position; after Gordon's yes `tools.equip_update: true` in `config/baseline.json` and watch whether the members pick a tool up
within a game day.
