# BUG-561 caravans fail `nothing_to_sell` / '0 sale items sent' beside 40 crafts: finished goods in bins are never hauled or offered
Status: fixed (offline, live-untested)
Severity: medium (no trade, no metal)
Found: 2026-11-06, Round 35 care/mood/trade (fix35-care), from the Run 16 FR-BUGS files and the runtime logs (read only)
Module: lua/dfllm/act.lua (TR.bring), lua/dfllm/trade.lua (lists_slice, step_mark)

## Actual
Run 16d i4 Trumpetrealms y404 (trade ledger Muboomon tick 163015942 `nothing_to_sell`, `inspect crafts` 40, the caravan carried 86 goods incl. iron and bronze
armor; kern.log "0 sale items sent to the depot" for 5 caravans) and Run 16a i1 Basementflew y387-y398 ("0 sale items sent", `nothing_listed`). Run 16b/16c sold goblets
and totems loose.

## Root cause
Two filters kept crafts in bins away. (1) `act.trade bring` skipped every item with `in_inventory` (and needs `on_ground`): a craft in a bin has `in_inventory`, and
DFHack's `markForTrade` refuses a contained item, so the bin was never marked. (2) `trade.lists_slice` skipped every container (`info.container`) on our side: the trade
list shows a bin as one entry (value = bin + contents), so even a bin that reached the depot was never offered. `economy`'s `inventory.crafts` counts the whole item vectors,
bins included, so the stock said 40 while nothing was loose. Neither said why: '0 sent' and `nothing_to_sell` named no reason.

## Fix
`bring`: a contained sale item whose bin is free (no BRING_SKIP flag, on the ground) and whose every content is a sale type marks the BIN once (counted by its
contents). `lists_slice`: a bin is a sale entry when everything in it passes the same filter as a loose item (sell list, no forbidden / owned / artifact / banned / unethical
content, nothing nested; value = the bin's perceived value, at least SELL_MIN); the entry's type is its contents' type (`BIN` if mixed). Mixed, forbidden or nested bins stay out.
Both count what they left out by reason: kern.log `trade: 0 sale items sent to the depot, left out: 3 forbid, 2 bin_mixed` and `trade: nothing to sell: 4 of ours listed
at the depot, not offered: 1 forbid, 3 value (sale value from 8, kinds 2)`. `trade.want` / `trade.sell` additions are untouched (the sell list filters the contents too).

## Tests
tests/lua/test_trade_act.lua (bring marks the bin once, reasons counted), tests/lua/test_trade.lua (a full bin is offered, a mixed one not, `nothing_to_sell` log).
Not decided offline: whether DF's trade screen lists a bin's contents as separate rows when the bin is at the depot (the code expects one entry, as the old test 'full
bins are never offered' did); a forbidden craft is still not unforbidden (a player's decision).

## Live check
See CHANGELOG "Round 35 (care)".
