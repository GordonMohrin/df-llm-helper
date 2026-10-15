# BUG-020 `embark.py scan` cannot place the rectangle: it stays where DF put it, the mouse injector has no effect
Status: open
Severity: medium (a new fort cannot be started without Gordon's hand; scan/embark are the only fair-play path)
Found: 2026-10-15 20:40, DF 53.16 restarted on virtual desktop 1, window resized to client 1716x1000 (the calibration), dfpilot main 95fe16d + local trade fix
Module: `tools/embark/embark.lua` (`W.inject`, `Inj`), `tools/embark/steps.lua` (`S.place`)

## Actual
`python tools/embark/embark.py newgame --world Zilirr` works (title -> world map). `scan 12,6` (also 16,5 / 20,6 / 28,14 / 30,10 / 10,18) always fails at step 2:
```
local.place: not done after 12 tries: rectangle at 224,132 (holding -817,-1449)      (second run: rectangle at 229,130, holding -1217,-1289)
```
The rectangle stays at a fixed position whatever pixel is held; the closed loop then "learns" a nonsense `k` from two identical observations and the hold pixel runs out of the window.
Isolated checks (Lua, same window): per-frame `gps.mouse_x/y` hold (v1 `hold.lua`) at (400,300), (800,500), (1200,700): `embark_pos_min` always 229,130; a standalone injector screen like `embark.lua`'s `Inj`
(focus `dfhack/lua/zinj`, `enabler.mouse_focus=true`, mouse written in `render`, `parent:logic()` in `onIdle`) at (600,400) and (1000,700): unchanged; cursor keys only move `zoom_cent` by 10 per press;
`gps.tile_pixel_x/y` = 10x15, grid 171x66 as calibrated. The v1 recipe (`zoom_cent` + hold + click) opens the popup for the same fixed rectangle (`light aquifer`).

## Expected
The rectangle follows the held/injected mouse as in the L0 capture (README: "rect_min = zoom_cent + k + floor((px - window centre) / 16)").

## Fix proposal
1. Do not learn `k` from a rectangle that did not move between two different held pixels; fail early with `rectangle does not follow the mouse` and the two pixels.
2. Find what changed since L0: DF restarted with `start_df_desktop1.ps1` and resized with MoveWindow after the first attempts; try the L0 state (window never moved after start) and a real OS mouse move over the window (SetCursorPos) to see whether DF only updates on SDL motion events.

Related: `tools/embark/README.md` (Live L0 findings), `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`
