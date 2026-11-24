# BUG-853 DF's own `cancels Drink: Well dry.` (1500 per 3000 gamelog lines live) did not show in the drink stall text
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17d i4 Girderroots (main 55e827ed), 24.11.2026 23:50: 1500 of 3000 gamelog lines were `<unit> cancels Drink: Well dry.`, the loudest signal of the log, and nothing in `stock.dwhy` or the drink status line named it.
Module: `lua/dfllm/economy.lua` (`M.drink_why`)

## Root cause
`M.drink_why` asked the tally only for brew cancels.

## Fix
Reporting only, no cure: `M.drink_why` puts `DF cancelled Drink 1500x in 7 d: Well dry` in front of the drink cause (state `stock.dwhy`, 80 bytes, brief and leiter) when the tally holds at least `economy.cancel.cx_min_n` (5) cancels of the job kind `drink` in the window; the container text follows while it fits. The reader (BUG-851) feeds the tally.

## Tests
`tests/lua/test_bug847_848_reader_pile.lua`: 1500 'Drink: Well dry' notes -> `drink_why` contains `DF cancelled Drink 1500x in 7 d: Well dry`, `df_reason(K, 'drink')` is that reason.

## Live-Erwartung
1. On i4 while drink is below the plan's target: `stock.dwhy` (the brief line `drink: ...`) starts with `DF cancelled Drink Nx in 7 d: Well dry`. PROMISED when the gamelog holds those lines and drink is below target; the 80 byte cap cuts the text that follows.
2. NOT promised: any change in behaviour (no cure added).
