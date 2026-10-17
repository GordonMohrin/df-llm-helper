# BUG-023 woodcutters in the Woodcutters detail never take FellTree jobs: the two axes lie in a bin in a stockpile and nobody fetches one
Status: open (Run 11 y434: the picks still not handed out); mitigated in 47d98c4 (offline, live-untested): detection, TOOL_BLOCKED (A), labor repair, miners out of everybody details; the pickup trigger `tools.equip_update` is on since Gordon's yes (2026-10-16); round 5: the diagnosis names DF's blocker (offline, live-untested)
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

## Live check y420 autumn d10 (697a95d, Run 10): the equipment request alone does not equip
After `dfllm reload` the kernel requested the equipment update again (kern.log: "holds no pick/axe: equipment update requested again"). About 2 game days later TOOL_BLOCKED #5887 `eq=2`: Miners 6 members, 4 with a pick in the Weapon slot, 2 without while 36 dig jobs are open; Woodcutters 1 member, 0 with an axe, 9 FellTree jobs open. 3 free picks and 5 free axes lie loose on the floor at (121,135,124) / (124,134,124). No tool was handed out by hand. Open: assign the tool through ownership or a Miners squad uniform (pick only), or stock the loose tools in a tools stockpile; reported to the dev session 2026-10-16.

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

## Third live check (Run 10 y421 spring, bbf75a4) and the release sweep
kern.log said `squad A: 3 positions give up their pick/axe spec`, `squad B: 1 ...`, but 15 game days later only 3 of 6 miners
held a pick; `inspect workload` tools: pick 9, pick_free 6, **pick_res 6**, axe 9, axe_free 6, axe_res 5; 8 of 9 picks were in
`plotinfo.equipment.items_assigned.WEAPON`. Woodcutters had 0 members. Causes:
1. The reservations sat in the positions' `assigned_items` (not, or not only, in the given-up spec's `assigned`), so the
   release of the replaced/removed spec found nothing to release, and older stranded reservations were never touched.
2. A feedback loop: economy caps a tool detail at the free UNRESERVED tools + the tools its members hold, and military kept
   only one tool per current member; the more the soldiers reserved, the smaller the details, the more spare tools the
   soldiers got (Woodcutters 0, so `keep.axe` fell to the floor 1).
3. The weapon guard still handed out picks beyond the miners' count (9 - 6 = 3).
Fix: military never gives a soldier an explicit pick spec (v1 E18: "keine Pick-Uniformvorgabe"); explicit pick specs are always
given up while guarded; the tools kept are at least economy's demand before its tool cap (`economy.tool_want()`); every upkeep a
sweep unassigns each pick/axe nobody carries that is reserved for a fort squad position without a weapon spec of that kind
(new `act.squad_release`, the squads screen's unassign: off the positions' lists, back to `items_unassigned`).
Tests: `tests/lua/test_military.lua` (`BUG-023: picks and axes reserved for positions without a spec of that kind ...`, the L6
guard test without picks), `tests/lua/test_kern_act.lua` (squad_release).
Live check: kern.log `military: N of M reserved picks/axes nobody carries unassigned`; `inspect what=workload` `pick_res`/`axe_res`
-> 0 (or only axes behind explicit axe specs); Woodcutters refilled by economy; members carry their tools within a game day.

## Fourth live check (Run 11 site98 y434 spring) and round 5: the diagnosis
TOOL_BLOCKED `Miners: ... hold no pick for 240 days, 14 dig jobs open; 3 free picks loose` with the release sweep (d4d1a96)
running and 240 days of equipment update requests (`equip='force'`, 697a95d). The picks 1836340 (103,108,139), 1885239
(112,87,142) and 1886349 (114,117,136) lay on the floor, not forbidden, not reserved (`pick_res` 0), on the citizens' walk
group. Nobody claimed a dig job: a dwarf without a work tool never takes one (v1 E18 Run 3: no "needs pick" cancel), so
DF's work tool assignment itself (`plotinfo.equipment.work_weapons`/`work_units`, filled on `update.weapon` from free
unreserved weapons, v1 E18 Run 5) never chose them.

What the code shows (proven):
- The census counted a pick marked for melting or owned by a dwarf as free (live L1b: the melt pile's marks kept the spare
  picks from the miners for a year; baseline only keeps picks out of melt piles from then on), and it ignored forbidden
  picks entirely: with only forbidden ones TOOL_BLOCKED never came (`free == 0`) and nothing unforbade them.
- Nothing kept a member from holding a second tool labor (MINE + CUTWOOD/HUNT) that no detail grants (a stray labor from
  before; DFHack's manipulator treats the three as mutually exclusive, autolabor: "the exclusive labors require
  equipment"); DF's own labor pass would clear it.
- TOOL_BLOCKED read nothing of DF's equipment state, the members' burrows or the civ alert, so four rounds could not say
  why DF did not hand the picks out.

Checked and not the cause: the census' pick is a weapon whose def has `skill_melee` MINING, the test DFHack's autolabor
`count_tools` uses for a mining tool; merchant goods, dumped, hostile and built-in items are never counted as free.

Suspected, not provable offline (the diagnosis reads each): the picks are not in `items_unassigned` (stuck in
`items_unmanifested` or in no list after their miners died in siege 3), DF still lists them as work tools of dead
miners (`work_weapons`/`work_units`), the members are paired with other (lost) picks, or a burrow (a lever room, the civ
alert) holds them. The two vectors are read as parallel (item i belongs to unit i; df-structures names them
`civilian_item_id`/`civilian_unit_id`).

Fix (Claude, 2026-10-16):
- **Diagnosis** (`economy.tool_diag`, daily while blocked, read-only): per free tool (4; forbidden ones after the free)
  its flags (in_job, owned, melt, forbid, artifact, hostile, encased, foreign, container), wear, DF's list
  (`u` unassigned, `a` assigned, `m` unmanifested, `-` none), its work tool pair (the unit and whether it is dead, gone,
  a soldier, a member or another), its owner, `far`, the building on its tile; per member without one (6) the labor,
  a second tool labor, DF's work tool pair (`wu=item:held|loose|forbidden|gone|held by N`), the burrows DF keeps him to
  (the civ alert's while it sounds, else `unit.burrows`) and how many free tools lie in them, how many share his walk
  group (snapshot.groups), `uniform_pickup` (with `*` when it lists a free tool), a pending `pickup_flags.update`, patient,
  his job. Blockers in order: `labor`, `tool2`, `alert`, `burrow`, `walk`, `pair`, `flag`, `pool`, `upair`, `fetch`,
  `pending`, else `none`. TOOL_BLOCKED gains `blk`, `bk`, `picks`, `units`, `civ`, `ww`, `forb`; a new blocker key is a
  cause (util/cadence), so the next report after `dfllm reload` comes with it. kern.log: `tools: Miners blocked (<keys>):
  <texts> | civ alert burrows N, work tool pairs N | picks: ... | members: ...` (at once after a load and whenever the
  diagnosis changes); `inspect workload` `key:'tools'` returns every record.
- **Melt marks** off a free pick/axe while members lack it (act.item_flag, the item sheet), as many a day as lack one.
- **Forbidden** picks/axes nobody carries are counted (`w_pick_forb`, `w_axe_forb`; also `_melt`, `_own`) and unforbidden by
  T.forbid (PEACE/RECOVERY, revealed, on the walk group) while members lack that tool; TOOL_BLOCKED comes with them too.
- **One tool labor:** `act.work_detail` joining Miners/Woodcutters/Hunters switches the other two tool labors off when no
  detail grants them (a second tool detail the unit is in keeps its labor); economy's repair makes that pass for such a
  member (`held a second tool labor (HUNT, no detail grants it)`, with the equipment request).
- Not built: an item move, an edit of `work_weapons`/`work_units`/`items_unmanifested` (no UI does them), a hauling job or
  a stockpile for the picks (v1 measured that bins and stockpiles do not matter), `setAutomaticProfessions` (DF's own work
  detail pass would hand the miners the everybody-does-this labors back).
Tests: `tests/lua/test_economy_tools.lua` (three `BUG-023 round 5` cases), `tests/lua/test_act_supply.lua` (one tool labor);
all fail on the old code.
Live check: after `dfllm reload` a TOOL_BLOCKED with `bk`/`blk` (within a game day) and the kern.log `tools: Miners blocked`
line; `dfllm cmd inspect '{"what":"workload","key":"tools"}'` for every record. Read: `pool` (a pick in no list or
unmanifested), `pair ... (dead N)` (DF keeps it as a dead miner's work tool), `upair` (a member paired with a lost pick),
`burrow`/`alert` (which burrow holds them), `fetch` (DF assigned it: why does he not walk there, see his job), `pending`
(DF did not process the request), `none` (nothing visible: tell the dev session with the records).
