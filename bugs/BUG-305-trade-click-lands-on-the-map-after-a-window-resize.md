# BUG-305 the kernel's Trade click can land on the map (a dwarf's unit sheet) once the DF window was relaunched or resized
Status: fixed (offline, live-untested)
Severity: high (the unit sheet then blocks the next caravans: BUG-286/287; Run 15 lost whole visits in three forts)
Found: 2026-10-29, Run 15 review of fix8 (Drillchamber, Inkintense, Earthboat runtimes, read-only)
Module: `lua/dfllm/act.lua` (`A.install_trade` `tr_click`, `TR.open`, `TR.offer`), `lua/dfllm/trade.lua` (`step_open`)

## Actual
commands.log `act.trade ["open",{"depot":...,"x":80,"y":15}]` in every fort before the relaunch at ~1793277607, `x":56` from
then until the blocks, `x":145` once the sheet was gone (window resized / windowed). The x is not stale: trade.lua reads it from
the live screen (label scan of the depot sheet) and act re-reads the label before the click. The click itself was the gap:
- Earthboat 151322779-151322979: seven label-verified clicks at 82,15 answered `clicked`, the trade screen never opened, the
  game ran on (the clicks went somewhere else); the next attempt 14 s later traded.
- The unit sheet (`dwarfmode/ViewSheets/UNIT/Overview`) the forts were blocked by came up between the kernel's last trade and the
  next caravan (BUG-286 Review); nobody issued a view, no other act clicks.

## Cause
`tr_click` (act.lua:199-202 on 9ef2ccb) wrote only `gps.mouse_x/y` (the interface tile) and sent `_MOUSE_L`. DFHack's Lua API
("simulateInput"): a click on the interface layer needs `mouse_x/y`, a click on the map uses `precise_mouse_x/y`. Those still held
the cached OS cursor, after the relaunch somewhere over the map; a click the sheet did not catch went to the map tile there, and a
dwarf there draws his unit sheet. Second gap: `gui.simulateInput` (hack/lua/gui.lua) sets `enabler.tracking_on = 1` in `push_key`
and never gives it back (its undo list covers the button fields only); BUG-228 showed live that with `tracking_on` forced to 1 DF
follows the cached OS cursor. The kernel never checked what its click opened: a unit sheet after the click was closed by BUG-286
as a leftover and the sheet opened and clicked again, up to `OPEN_TRIES` 8 clicks.

## Fix
- act.lua `tr_click` (used by the depot sheet's Trade and the trade screen's Trade): both mice point at the target tile, the precise
  pixel at its centre (`x * tile_pixel_x + tile_pixel_x // 2`, the tile size read from gps like tools/embark); without a known tile
  size there is no click (`no interface tile size: no click`). After the click the four mouse fields and `enabler.tracking_on`
  are written back to what they were (pcall; a missing field is a no-op). A click the interface does not catch thus falls on the
  button's own tile (under the sheet), like a player's click there, never on the cached cursor.
- trade.lua `step_open`: after a depot-sheet click (`f.aim`) the next run checks the screen. A ViewSheets/Trade screen that is
  neither the depot sheet nor the trade screen is logged `trade: the Trade click at X,Y opened <focus> instead of the trade screen
  (n of 2)` and closed as ours (BUG-286 `OWN`); at `MIS_MAX` 2 the attempt ends `misclick` (not retried), so the kernel never
  keeps clicking the map. The mark is dropped when the kernel reopens the sheet from the map (review), so a leftover after
  that reopen is BUG-286's, not counted as a misclick.

## Tests
tests/lua/test_bug305_trade_click.lua (all 5 fail on 9ef2ccb): the fake DF routes a click to the map unless both mice name the
same interface tile; the sheet click and the trade-screen click write the tile centre, no map click, no unit sheet; mouse and
`tracking_on` given back (a 1 before stays 1); no tile size, no click; a click that opens a unit sheet is named, the sheet closed,
exactly `MIS_MAX` clicks, the visit fails `misclick`, never `blocked`. Fakes in test_trade_act.lua and trade_world.lua carry a tile
size now.

## Live check
After a relaunch or a window resize, the next caravan: commands.log `open ... x:N` then `mark`/`offer` in the same second (the
click opened the trade screen at once, no click series like Earthboat's seven), no `ViewSheets/UNIT` afterwards, and kern.log has
no `opened ... instead of the trade screen`. That line or CARAVAN `failed: misclick` means DF still sends the click elsewhere:
read the focus it names and `gps.tile_pixel_x/y` against the window size. Uncertain offline: whether DF 53.16 hit-tests the depot
sheet button by `mouse_x/y` or by the precise pixel (both now name the same tile), and whether the unit sheet of Run 15 came from
this click or from a click outside the kernel.
