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
Drillchamber the same at 151417331 (blocked at 151727786), Earthboat `open`/`open x56`/`close` at 153333217 (nothing wanted;
blocked at 153438667, then two more visits).

Review (same logs, read-only), against the "DF left it after our close" reading: (1) when the sheet came up is not logged; the
blocked visits began 12-36 real minutes after the kernel's close, and the arbiter dismissed other popups in between (Inkintense a
mood popup 13 s after the close, Earthboat 68 s). (2) The sheet did not stand until a DF reload: Drillchamber traded again at
151827473 with no reload or kernel boot, Inkintense was still blocked at 151745623 after a 1 h pause/resume (no reload) and traded
at 151750451. (3) All blocks fall in one window layout: the depot sheet's Trade button stood at x80 in every fort before the
relaunch at ~1793277607, at x56 for every trade from then until the blocks, and at x145 once the sheet was gone. A real click into
a resized window (a dwarf on the map) would draw the same sheet. So the 3 s window below may never catch the live case; BUG-287
is the net that does.

## Cause
The kernel did not track which screens it opened. `TR.close` (act.lua:369-393) sends LEAVESCREEN only while the focus reads
Trade/ViewSheets within that one call; what DF 53.16 shows after it (here a unit sheet; inferred from the logs, DF falls back from
the closed trade screen to a sheet after the call) was not the kernel's any more. `close_ui`/`sweep` (trade.lua:1027-1046 on abc2f95)
know only the depot sheet and the trade screen as their own, and `step_open` (trade.lua:1495-1496 on abc2f95) took every other
screen for the player's: `ui_busy` for ever. Which DF path draws the unit sheet is not proven offline (see Review above: the
timing does not support it either; the kernel-side gap, no record of its own screens, is real regardless).

## Fix
trade.lua `OWN` (persisted `m.trade.ui`): ownership starts when trade opens the depot sheet from the map and ends only after the map
has stood `SETTLE_MS` (3 s real) after the kernel's close. While owned, a `dwarfmode/ViewSheets/*` or `dwarfmode/Trade*` screen on
top (no DFHack dialog) is a leftover of ours: closed with act.trade `close` (LEAVESCREEN = the player's Esc), logged `trade: closed
<focus>, left open after the kernel's own trade screen`, at most `LEFT_TRIES` 4 times (then it is the player's). In OPEN the same
check runs before a screen counts as the player's, so a sheet of ours never ends a visit as `ui_busy`. Any other screen ends the
ownership: a screen the player opens later is never touched (a sheet he opens inside the 3 s after our close is taken for ours
and closed once). The module runs every UI_MS while it owns a screen.

## Tests
`tests/lua/test_bug286_287_sheet.lua`: a leftover unit sheet after the close is closed; a unit sheet instead of the depot sheet
does not block; a sheet the player opens after the map settled stays (guard, passes before too). The first two fail on abc2f95.

## Live check
After the next trade: kern.log `trade: closed dwarfmode/ViewSheets/UNIT/Overview, left open after the kernel's own trade screen`
(proves DF draws it) or none (then it comes from elsewhere: watch for BUG-287's DECISION_NEEDED trade_screen); the next caravan
trades without `blocked`. If DF draws the sheet later than 3 s after the close, it still blocks (BUG-287 asks); do not just raise
SETTLE_MS: a longer window closes more of the player's own sheets. Note the Trade button x in commands.log (`open` x,y) at each
block: x56 again points at the window layout / a real click, not at the kernel.
