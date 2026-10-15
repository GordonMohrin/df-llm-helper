# BUG-016 two caravans were lost because a unit sheet stayed open in the game window: trade waits for ever on `ui_busy`
Status: open
Severity: medium (every trade of the year is lost silently; 100 sale items are hauled to the depot again every 12 s meanwhile)
Found: 2026-10-15 17:20-17:50, test fort (copy of autosave 3, y373), dfpilot main 95fe16d, Claude playing
Module: `lua/dfllm/trade.lua:897-914` (`ui_busy`), `trade.lua:1210` (PHASE_MS), arbiter popup handling

## Actual
```
kern.log   trade: a player screen is open; trying again later        (every ~12 s, 25 times)
           trade: 100 sale items sent to the depot                   (right after each, 25 times)
           trade: time out in WAIT: 155 time left, at depot 32928 ticks, trader true, goods 15, broker req true anyone true
events     #11948 CARAVAN trade with Muboomon failed: gone   (ratio 0)
           #11980 CARAVAN trade with Catten failed: time     (ratio 0)
focus      dwarfmode/ViewSheets/UNIT/Overview  (unchanged for > 1 h; read every 3 s)
```
Before that the same module traded fine (ratio 1.69 and 1.76, #11707 / #11815). `unmet` list of the failed ledger: bar:iron, bar:copper, bar:bronze, leather, seeds, pick, axe, anvil, wood, meat.
I closed the sheet with `gui.simulateInput(dfhack.gui.getDFViewscreen(true),'LEAVESCREEN')` (focus back to `dwarfmode/Default`); nothing in the kernel did that.

## Expected
A sheet that has been open for minutes while a caravan is waiting is not a "player screen" any more: the arbiter closes viewsheets (it already dismisses popups,
`arbiter act.dismiss_popup`), or trade reports `TRADE_BLOCKED ui: dwarfmode/ViewSheets/UNIT/Overview open for N min, caravan leaves in T` (class A) so the player can close it.

## Fix proposal
1. In `trade`: when `ui_busy` lasts longer than a threshold (say 3 game days or 60 s) and the focus is a plain `ViewSheets/*`, call the arbiter's close action (LEAVESCREEN), like the popup path.
2. Do not send "100 sale items to the depot" on every retry (25 repeats): once per caravan, or only when the pile at the depot fell.
3. Raise a class A `TRADE_FAILED` with the reason when a caravan leaves with ratio 0, not only a class B `CARAVAN ... failed`.

Related: FR-trade, BUG-008 (event repeats)

## Confirmation (18:25)
After the sheet was closed (focus `dwarfmode/Default`) the next caravan traded at once: `#12056 CARAVAN traded with Muboomon, ratio 1.65`. So the open unit sheet was the only blocker.
