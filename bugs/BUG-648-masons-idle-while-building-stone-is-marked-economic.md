# BUG-648 Masons idle while building stone is marked economic
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16c i3 Wallfree y384-y386: Masons 8-11 shops, 0 jobs; doors, tables, chests, thrones 24-44 days without a job beside 350 blocks and 37-53 boulders; DF cancels 'Needs non-economic hard stone boulders' (rock there: CLAYSTONE; 16d i4 MUDSTONE)
Module: `lua/dfllm/act.lua`, `lua/dfllm/util/contract.lua`, `lua/dfllm/economy.lua` (`M.stone_unmark`, `M.hard_report`)

## Actual
Furniture and doors wait for months in a stone fort; the player is asked `no_hard_stone` with no way out but the caravans.

## Root cause
DF takes furniture only from hard stone that is not marked economic in the stone-use screen (`plotinfo.economic_stone`). The census already leaves economic stone out, so a fort whose only rock is marked economic reached 'none usable' with a question and no repair. Whether claystone is marked economic by default could not be read offline (the vanilla STONE_TEMPLATE has ITEMS_HARD, claystone adds no override); the 'denied' case (census says usable, DF cancels anyway) stays unexplained.

## Fix
`hard_report` first reads the free boulders by material (kern.log `free boulders by material: CLAYSTONE x38 (hard, economic)`), then clears the economic mark through the new `act.stone_economic` (`economic_stone[idx] = 0`, the write gui/advfort.lua does; DF writes live in act.lua only) of every free material that is hard (ITEMS_HARD), no ore and no flux. The material cache is dropped, the denial memory reset, the Masons take the stone at the next census; no question when something was cleared. Soft stone (no ITEMS_HARD) stays out and keeps the old question.

## Tests
`tests/lua/test_kern_act.lua` (stone_economic), `tests/lua/test_bug544_547_stone_manager.lua` (+2, one existing case moved to soft stone: a hard economic stone is cleared now)

## Live check
Wallfree: after the next 'Needs non-economic hard stone' cancels, kern.log lists the boulder materials; if claystone is economic the Masons start. If kern.log shows hard and not economic for claystone, DF's refusal has another cause (to read from that line).
