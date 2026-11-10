# BUG-630 `nothing_to_sell` in a fort with a depot and no Craftsdwarf's workshop: no craft is ever made for the caravans
Status: fixed (offline, live-untested)
Severity: medium (no trade, no bars, picks or seeds from the caravans for years)
Found: 2026-11-10, Run 16b i2 Valleyhame y376-y383 (a poor soil fort; the caravan came, `nothing_to_sell`; no Craftsdwarf's workshop stood)
Module: `lua/dfllm/economy.lua` (`M.trade_goods`), `dfpilot/wake.py` (PROJECT_REQUEST workshops why list)

## Actual
`M.trade_goods` (BUG-582) keeps 30 crafts to sell, but only when the crafts are on the sell list, a depot stands AND a Craftsdwarf's workshop stands. A fort without that shop never made a craft, nothing asked for the shop, and an EMPTY sell list (which sells whatever lies at the depot) was not counted as selling crafts.

## Root cause
`trade_goods`: `sell` was true only for a list naming `crafts`; `ws_any(r.f, tg.ws)` returned silently when the shop was missing.

## Fix
`economy.trade_goods`: an empty sell list counts as selling crafts; with a depot standing, fewer crafts than `trade_goods.min` and no Craftsdwarf's workshop, `M.ws_ask(K, p, 'trade', {'Craftsdwarfs'}, food.request_days)` sends one `PROJECT_REQUEST workshops why=trade types=[Craftsdwarfs]` (paced: the same set repeats at 14, 28, 56 days and wall seconds); `wake.py` places it like `gear` / `missing`. With the shop standing the BUG-582 orders (bone, wood, stone) run as before.

## Tests
`tests/lua/test_bug629_630_cook.lua` (2 for this bug: depot + `crafts` on the list + no shop -> one request; empty list the same; no depot or the shop standing -> none).

## Live check
A fort with a built trade depot and no Craftsdwarf's workshop: `kern.log` `trade: N crafts < 30 to sell and no Craftsdwarf workshop: asking for Craftsdwarfs`, follow places a workshops project with only that shop, then `order dfllm:trade_goods`.

## Open
The shop is asked for only once the depot stands (no craft before there is a buyer); a poor fort with neither wood, bone nor free stone still has nothing to make crafts from (the BUG-582 sources); other `nothing_to_sell` causes (forbidden, bins, values) are BUG-561 / BUG-609 / BUG-627.
