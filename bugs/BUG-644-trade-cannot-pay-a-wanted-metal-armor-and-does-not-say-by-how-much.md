# BUG-644 The caravan sells a metal armor the fort cannot pay for: only mugs and rings offered, no word how big the gap is
Status: fixed (offline, live-untested); open: a fort with no spare crafts or gear still cannot buy it
Severity: medium (armor:metal / bars stayed `value` for years)
Found: 2026-11-10, Run 16d i4 Trumpetrealms y432 (ledger `sold GOBLET/BRACELET/AMULET 208`, `unmet armor:metal:value`), Run 16a i1 (every caravan `nothing_to_sell` beside 100 backpacks and flasks)
Module: `lua/dfllm/trade.lua` (`L.gaps`, `lists_slice`, `step_mark`, `wants`, `ledger`), `lua/dfllm/act.lua` (`TR.bring`)

## Actual
The sale pool was what the sell list took: crafts only. `L.plan` buys the wants in list order as far as the pool pays; a metal armor worth 400 needs ~890 of sale value (display ratio 1.5, margin, merchant factor), the pool was 281, the ledger said `value` with no number. Beside it, `TR.bring` (act.lua, old loop over `a.types` sorted alphabetically) filled its cap (`BRING_MAX` 100) with the first types in the alphabet, so cheap amulets crowded out worth.

## Fix
- `L.gaps(buys, sells, want, fac)` (trade.lua:429): per want, the sale value its cheapest entry needs against the whole pool. The ledger (trade.lua:1325) writes `armor:metal:value[need=891,pool=281]` (also for a `ratio` failure); no brackets when the pool would pay.
- `CFG.EXTRA`: items of `L.EXTRA` (the craft types, backpack, flask, quiver) that lie at the depot but off the sell list are collected while the lists are read (`lists_slice`, trade.lua:1192, `j.extra`); when a gap exists (or the list takes nothing here) they are offered too (`step_mark`, trade.lua:1930), and the plan sells only as many as it needs, most valuable first. Kinds the player took out with `sell_remove` (`ov.noauto`) are never offered.
- The kinds offered are remembered (`st.x`, `XKEEP` two years) and join the sell list (`wants` -> `L.surplus_sell` `extra`), so the next haul brings them to the depot; `trade.want` replies show them.
- `TR.bring` (act.lua:485): all free items and bins are read first, then marked most valuable first (a bin by the sum of its contents), so the cap no longer fills alphabetically.

## Tests
`tests/lua/test_bug642_644_trade.lua` (gaps; an armor paid with spare backpacks and flasks, kinds learned, `sell_remove` sticks; no gap, no extra; `EXTRA = false` keeps the list and the ledger names the gap; an empty result sells the gear), `tests/lua/test_trade_act.lua` (bring by value under a cap).

## Live check
`inspect what=trade` after a caravan: `ledger[0].unmet` with `[need=..,pool=..]`; kern.log `trade: value gap: armor:metal needs N of M: K more items of the depot are offered`; `trade.want` shows `backpack` / `flask` in `sell`.
Risk: spare backpacks / flasks / quivers also feed uniforms; the kernel sells only what lies at the depot and only on a gap, but it does not count the soldiers' reserve.
