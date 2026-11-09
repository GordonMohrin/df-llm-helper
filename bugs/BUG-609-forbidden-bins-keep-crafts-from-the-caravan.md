# BUG-609 Forbidden bins keep the crafts from the caravan, nothing_to_sell does not say which kinds
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-09, Run 16a i1 Basementflew y426-y429 (`bin_forbid` 136 on every haul, 0 sent, `nothing_to_sell` after `100 sale items sent`, 'kind' 148-245)
Module: `lua/dfllm/act.lua` (`TR.bring`), `lua/dfllm/trade.lua` (`step_mark`, `ledger`, `M.CFG.UNFORBID_BINS`)

## Actual
Forbidden bins keep the crafts from the caravan, nothing_to_sell does not say which kinds.

## Root cause
`TR.bring` skipped a bin that was forbidden, or whose crafts were (`bin_forbid`), and counted a forbidden craft inside a bin as a loose forbidden item. No code of the kernel forbids a bin or a craft: the only `forbid = true` write is care's reserve (`reserve_item`: boulders, logs, bone, shell, leather, cloth, thread, gems, bars; never a container or a craft), so the forbid is the game's or the player's. 148-245 items at the depot were off the sell list (`kind`) and the log said only the number.

## Fix
`act.lua` `TR.bring` (`a.unforbid`, sent by trade with `trade.UNFORBID_BINS` true): a forbidden bin on the ground whose crafts are all sale types, or a free bin with a forbidden craft, is unforbidden and marked (`a.freed`); a loose forbidden craft, a mixed bin and an old call stay as they were. `trade.lua`: the haul log says `N forbidden bin(s) / crafts unforbidden`; `nothing to sell` lists the item types the sell list leaves out (`off the sell list: 2 FIGURINE, 1 GOBLET`) and the ledger cause carries them (`nothing_to_sell[forbid=3,kind=148(BAR90+CLOTH40)]`).

## Tests
`tests/lua/test_trade_act.lua` (+1, bring with unforbid), `tests/lua/test_trade.lua` (+1, the kinds in the log and the ledger)

## Live check
kern.log `trade: N sale items sent ... ; M forbidden bin(s) / crafts unforbidden` instead of `left out: bin_forbid`; a failed visit's ledger unmet reads `nothing_to_sell[kind=...]`.
