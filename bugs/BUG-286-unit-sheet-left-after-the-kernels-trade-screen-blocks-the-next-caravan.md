# BUG-286 a unit sheet left after the kernel's own trade screen blocks every later caravan as "a player screen"
Status: fixed (offline, live-untested)
Severity: high (whole caravans lost: Drillchamber 1, Inkintense 2, Earthboat 3 visits in Run 15)
Found: 2026-10-29, Run 15 (DF 53.16; Inkintense, Earthboat, Drillchamber runtimes, read-only)
Module: `lua/dfllm/trade.lua` (`close_ui`, `own_ui`/`sweep`, `step_open`), `lua/dfllm/act.lua` (`TR.open`, `TR.close`)

## Actual
`CARAVAN trade with X blocked: a player screen is open (dwarfmode/ViewSheets/UNIT/Overview); close it`, kern.log `trade: a player
screen is open; trying again later` x7-x14, then `failed: time (OPEN, 1990 ticks left)`. Nobody issued a view (cli.log has no verb).
commands.log between the visit before and the blocked one holds no act that opens a sheet: request_broker only writes the depot's
trade_flags, dismiss_popup only erases world.status.popups; neither touches the UI. In all three forts the last UI actions before
the sheet were the kernel's own: Inkintense `open`/`open x56`/`mark`/`offer`/`close` at 151318626 (blocked at 151417703),
Drillchamber the same at 151417331 (blocked at 151727786), Earthboat `open`/`open x56`/`close` at 153333217 (blocked at 153438667,
then two more visits). The sheet stood until DF was reloaded (Inkintense 151744910).

## Cause
The kernel did not track which screens it opened. `TR.close` (act.lua:369-393) sends LEAVESCREEN only while the focus reads
Trade/ViewSheets within that one call; what DF 53.16 shows after it (here a unit sheet; inferred from the logs, DF falls back from
the closed trade screen to a sheet after the call) was not the kernel's any more. `close_ui`/`sweep` (trade.lua:1027-1046 on abc2f95)
know only the depot sheet and the trade screen as their own, and `step_open` (trade.lua:1495-1496 on abc2f95) took every other
screen for the player's: `ui_busy` for ever. Which DF path draws the unit sheet is not proven offline.

## Fix
trade.lua `OWN` (persisted `m.trade.ui`): ownership starts when trade opens the depot sheet from the map and ends only after the map
has stood `SETTLE_MS` (3 s real) after the kernel's close. While owned, a `dwarfmode/ViewSheets/*` or `dwarfmode/Trade*` screen on
top (no DFHack dialog) is a leftover of ours: closed with act.trade `close` (LEAVESCREEN = the player's Esc), logged `trade: closed
<focus>, left open after the kernel's own trade screen`, at most `LEFT_TRIES` 4 times (then it is the player's). In OPEN the same
check runs before a screen counts as the player's, so a sheet of ours never ends a visit as `ui_busy`. Any other screen ends the
ownership: a screen the player opens later is never touched. The module runs every UI_MS while it owns a screen.

## Tests
`tests/lua/test_bug286_287_sheet.lua`: a leftover unit sheet after the close is closed; a unit sheet instead of the depot sheet
does not block; a sheet the player opens after the map settled stays (guard, passes before too). The first two fail on abc2f95.

## Live check
After the next trade: kern.log `trade: closed dwarfmode/ViewSheets/UNIT/Overview, left open after the kernel's own trade screen`
(proves DF draws it) or none (then it comes from elsewhere: watch for BUG-287's DECISION_NEEDED trade_screen); the next caravan
trades without `blocked`. If DF draws the sheet later than 3 s after the close, it still blocks (then raise SETTLE_MS).
