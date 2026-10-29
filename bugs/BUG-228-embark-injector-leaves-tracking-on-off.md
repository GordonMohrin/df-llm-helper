# BUG-228 embark scan: DF ignores the injected mouse while enabler.tracking_on is 0 (the cause of BUG-020)
Status: fixed (offline, live-untested)
Severity: medium (no new fort through `embark.py scan`/`embark`; the Run 15 embark was done by hand clicks)
Found: 2026-10-29, Run 15 embark on i2 (tool findings 1 and 2)
Module: `tools/embark/embark.lua` (`Inj`, `W.track`, `W.release_all`)

## Actual
`df.global.enabler.tracking_on` drops to 0 (likely a mouse-leave event on the DF window). At 0 DF ignores the mouse the
injector writes: the placing rectangle sticks (BUG-020: "rectangle does not follow the mouse") and the site panel stays
empty (scan read 0 panels even when a workaround placed the rectangle). Setting `tracking_on = 1` in the injector's render
made rectangle and panel follow. Forcing it permanently breaks the other path: without the injector DF uses the cached OS
cursor and the rectangle jumps ("rectangle moved before the click").

## Fix
`W.track(on)` remembers `enabler.tracking_on` before the injector and sets it to 1; `Inj:render` and `Inj:onIdle` (before the
native logic) call `W.track(true)`; `Inj:onDismiss` and `W.release_all` call `W.track(false)`, which restores the remembered
value. A missing field is a no-op (pcall). Nothing else changes: the injector is still shown only while the local map is used
and dismissed before Confirm and at the end of every run.

## Tests
`tests/lua/test_embark_entry.lua` `BUG-228: ...`: the fake DF's rectangle and panel follow the mouse only while
`tracking_on == 1`; with a minimal gui.Screen the pump runs the injector's logic and render each frame. The scan places the
rectangle at 134,486 and reads the panel, `tracking_on` was 1 meanwhile and is 0 again afterwards; a 1 before the run stays
1. On 5e9e719 the scan fails with `local.place: rectangle does not follow the mouse` (the live BUG-020 symptom).
`tests/test_embark.py::test_bug228_injector_restores_tracking_on`.

## Live check
Embark world map, DF unfocused on desktop 1: `python tools/embark/embark.py scan 12,6` places the rectangle (no
"does not follow the mouse") and the result row has panel facts (`rec.read > 0`, not `panel` in fails). After the run
`python tools/embark/embark.py state` still works and the rectangle follows Gordon's real mouse again (tracking_on restored).
