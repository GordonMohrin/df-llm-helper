# BUG-151 view: after the player ended a follow by moving the camera, a bare `view` said "no saved player position (no view has moved the camera yet)"
Status: fixed (offline, live-untested)
Severity: low (a wrong reason: views had moved the camera)
Found: 2026-10-28, live test i1 (FR-88c, NEW4); confirmed by the verifier
Module: `lua/dfllm/viewlib.lua` (`V.step`, `V.verb`)

## Actual
`V.step` cleared `st.home` and `st.after` when it saw the player's camera move, so the next bare view failed at "no saved player position"
instead of the intended answer "the player has moved the camera since the last view: it is his, nothing to restore".

## Fix
`V.step` sets `st.given` when the player takes the camera; the next bare view answers "it is his, nothing to restore" (ok) once and clears
it; a new view series clears it too. tests/lua/test_view.lua had pinned the old text and now expects the new one.

## Tests (`tests/lua/test_bug150_151_view.lua`)
The follow ended by the player, then a bare view (fails on main), then "no saved player position", then a new series restores again.
