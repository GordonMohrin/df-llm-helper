# BUG-023 woodcutters in the Woodcutters detail never take FellTree jobs: the two axes lie in a bin in a stockpile and nobody fetches one
Status: open (workaround found live: put the axe into the woodcutter's hand)
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
