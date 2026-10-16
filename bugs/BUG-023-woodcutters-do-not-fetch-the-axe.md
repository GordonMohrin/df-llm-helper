# BUG-023 woodcutters in the Woodcutters detail never take FellTree jobs: the two axes lie in a bin in a stockpile and nobody fetches one
Status: mitigated in 47d98c4 (offline, live-untested): detection, TOOL_BLOCKED (A), labor repair, miners out of everybody details; the pickup trigger `tools.equip_update` is on since Gordon's yes (2026-10-16)
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
- **Equipment update [live-untested, on since Gordon's yes 2026-10-16]:** `tools.equip_update = true` makes `act.work_detail` set the dwarf's
  `uniform.pickup_flags.update` and `plotinfo.equipment.update.weapon` when it switches a tool labor on. That is the request
  the engine hands work picks and axes out on (v1 E18 Run 5: without the per-dwarf flag non-squad miners never got a work
  pick); the dwarf still walks to the tool himself. It is a write to a unit field, so v1 kept it in the exception register
  (FP08): switch it on only with Gordon's yes. Gordon said yes on 2026-10-16: `config/baseline.json` `tools.equip_update: true`
  (RULES §1.1 exception, `docs/v2/DECISIONS.md`).

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

## Live check after the switch (2026-10-16, Run 10 y420) and fix
With `tools.equip_update` on (6455f16) nothing changed for 16+ game days: Woodcutters 1 member, 0 with an axe (TOOL_BLOCKED
#5725 "no axe for 5 days, 9 FellTree jobs open, 5 free axes"), Miners 6 members, 4 with a pick. Cause: the request was only
made when `act.work_detail` switched a labor on or added a member; the members had been added before the switch.
Fix: economy's tool repair: a member without its tool in hand while free tools exist gets `act.work_detail(..., {equip =
'force'})` (the equipment update request again) at the first pass after a load and then every `tools.repair_days`; a member the
kernel adds in a pass is not repaired in the same pass. TOOL_BLOCKED carries `eq` (requests since the block began) and
`eq_days`; the hint says `equipment update requested N times (last D days ago), no tool picked up yet`. Tests in
`tests/lua/test_economy_tools.lua` (fail on the old code). Live check: after `dfllm reload`, kern.log `Woodcutters: ... holds no
axe: equipment update requested again`; within a game day the member should carry an axe. If TOOL_BLOCKED still comes with
`eq` >= 2, the engine's request is not enough and the cause lies elsewhere (tell Gordon; no tool is put into a hand).

## Second live check (Run 10 y420 autumn) and the reservation fix
The repeated request was not enough either: TOOL_BLOCKED #5887 `Miners: 2 of 6 hold no pick for 4 days, 36 dig jobs open; 3 free
picks (3 loose, 3 reserved by squad uniforms) [eq=2]`; Woodcutters 0 of 1 with an axe, 5 free axes. The free tools lay loose on
the floor, not in a container. Cause (v1 E18 Run 5, measured then): DF hands work tools (`plotinfo.equipment.work_weapons`) out
only from UNRESERVED free tools; an explicit pick/axe weapon spec of a squad position reserves free tools in position order
(`spec.assigned`, `position.assigned_items`, global `items_assigned`), and military's weapon guard gave soldiers every pick beyond
a fixed `PICK_KEEP` 2 (axes beyond `AXE_KEEP` 1), whatever the tool details needed. Fix:
- military: the tools kept for the civilians are one pick per Miners member and one axe per Woodcutters member (floors 2/1);
  explicit pick/axe specs beyond the spare tools are re-planned (other melee weapons, else none), soldiers without the tool in
  hand first (`military: squad A: N positions give up their pick/axe spec`).
- act: `squad_uniform` (replace) takes the replaced specs' items off the position, and `squad_uniform`/`squad_unequip` give an
  item that no position lists and nobody carries back from `items_assigned` to `items_unassigned` (what the squads screen's
  removal does; v1 `pickfix` did the same by hand).
Tests: `tests/lua/test_military.lua` (two BUG-023 cases), `tests/lua/test_kern_act.lua` (release); all fail on the old code.
Live check: kern.log `give up their pick/axe spec`; `inspect workload` `tools` shows `pick_res`/`axe_res` falling to 0; with the
equipment update requests the miners/woodcutters should carry a tool within a game day.
