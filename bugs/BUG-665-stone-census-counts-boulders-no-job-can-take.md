# BUG-665 The stone census counts boulders no job can take (46-84 "usable", every rock job and mood "none hard stone")
Status: fixed (offline, live-untested); open: why DF refuses the sedimentary stone itself is read from the game at the next denial (kern.log)
Severity: high
Found: 2026-11-10, Run 16b i2 Valleyhame y377-y379 (census boulders 46-84, every mood and rock job 'none hard stone', a Possessed mood went berserk, 2 dead), Run 16a i1 Basementflew y466 (DECISION 'DF cancels rock jobs x3 "Needs non-economic hard stone" beside 30 boulders counted usable', the 30 lay in the flooded z117), Run 16d i4 Trumpetrealms (100 boulders, 0 usable, mudstone / claystone / kaolinite)
Module: `lua/dfllm/economy.lua` (census BOULDER branch, `M.df_refuses`, `M.boulder_probe`, `M.hard_report`), `lua/dfllm/act.lua` (`I.mat_refused`), `lua/dfllm/snapshot.lua` (`M.far` strict, `M.spot`)

## Actual
The census said 30-84 usable boulders for hundreds of days; DF cancelled every mason, mechanic and mood job for want of "non-economic hard stone"; the kernel only learnt it from three cancels and then knew no more than "denied".

## Root cause (read from the logs)
- Not the material flags: the kern.log lines of BUG-648 ('free boulders by material') list Valleyhame CONGLOMERATE / SANDSTONE / CHERT / SHALE, Basementflew SANDSTONE, Trumpetrealms MUDSTONE / CLAYSTONE / KAOLINITE as `hard` and not `economic` (raws: ITEMS_HARD through STONE_TEMPLATE, economic_stone byte 0). Economic and soft stone are not the mismatch there (only the clays are 'soft, economic', and those were already out).
- Not forbidden stone: the census skips `forbid`, `dump`, `in_building`, `construction`.
- Out of reach, two holes: the census BOULDER branch asked `snapshot.far(x,y,z)`, which answers "near" for a tile with NO walkable group (`snapshot.lua` `grp ~= 0 and not home.set[grp]`): a flooded or walled-in tile (Basementflew z117) is near. And a boulder an existing job holds (`flags.in_job`: a hauler's or builder's claim that never ends) was counted free; DF's job picker skips it. The constant '46' of Valleyhame over 200 days fits claimed or unreachable boulders.
- What DF takes as "non-economic hard stone" was never asked of the game; the census used its own reading of the flags.

## Fix
- `snapshot.far(K,x,y,z,strict)`: with `strict`, group 0 is far. The census asks strict for boulders only (food, drink, logs keep the plain read): a boulder at a tile without a walkable group counts as `rock_far`; one with `in_job` as new `rock_busy`. Neither is in `rock`.
- `act.mat_refused(idx)` (read only; `economy.df_refuses` asks it): a job_item for a BOULDER with `non_economic` and `hard` through `dfhack.job.isSuitableMaterial` (the check the mood filters already use). A plain building stone (hard, not economic, no ore, no flux) the game refuses is `rock_bad`: not counted usable, named in kern.log 'free boulders by material' as `refused by the game`. `M.ASK_DF = false` skips the question; any fault or missing API answers "not refused" (the old census).
- When DF cancels anyway ('denied'), `M.boulder_probe` logs where the boulders counted usable lie (`30 usable boulders lie at z117 x30; walk groups g0 x30; hidden x2 ...`): level, walk group, hidden / owned / carried.
- The 'none' question names the refused rock (`sandstone, chert refused`), says to dig another rock layer (`bp sites explore`) or trade, and carries the wooden-door command (BUG-666).

## Tests
`tests/lua/test_bug665_668_stone_wood.lua` (rock_far / rock_busy, plain far unchanged, game verdict, ASK_DF off, question text, probe line), `tests/lua/test_bug416_417_reach_groups.lua` (strict far), `tests/lua/test_kern_act.lua` (mat_refused), `tests/lua/test_kern_load.lua` (the in_job bit is read from the census' flag word), `tests/test_bug665_668_f43_stone.py`.

## Live check
After the next 'Needs non-economic hard stone' cancel read kern.log: `free boulders by material` shows `refused by the game` for the materials DFHack refuses (then it is the stone type: another layer, trade, wood) or, when none is refused, `DF refuses boulders the census counts usable: ... lie at zN, walk groups gM` names the level and group to look at. `inspect what=census` rock / rock_far / rock_busy.
Open: if DFHack's verdict is "suitable" for every material and the boulders are in reach, the cause is outside what the kernel can read (a burrow restriction, a claimed item); the probe line is the evidence.
