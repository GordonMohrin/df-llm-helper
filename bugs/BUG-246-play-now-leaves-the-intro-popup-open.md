# BUG-246 embark --play-now leaves the intro popup open
Status: fixed (offline, live-untested)
Severity: low (the fort waits on an open popup until the player clicks Okay; live L6 showed a fort where nobody worked)
Found: 2026-10-29, Run 15c Inkintense (i1), `embark 7,10,10,6 --play-now`
Module: `tools/embark/steps.lua` (`S.intro`, `S.INTRO`, `S.intro_shown`)

## Actual
"all steps done", the fort loaded, but the intro popup "A Dwarven Outpost ... Okay" (row 46) was still open. `fort.intro`
looked only for the text "Strike the earth" and ended at once with "no intro popup" when the popup was not drawn yet.

## Fix
The intro is any of "Strike the earth", "Dwarven Outpost", "expedition has arrived". `fort.intro` looks for it for
`intro_polls` (ui.json, default 40, about 10 s) before it says there is none, clicks the exact `Okay` cell only while a marker
is shown, clicks again when the popup is still open 12 polls later (at most 3 clicks, then an optional-step warning).

## Tests
`tests/lua/test_embark_fix6.lua` `BUG-246 ...` (a popup drawn 2 s after the fort with "A Dwarven Outpost" and no "Strike the
earth": closed by one Okay; no popup: nothing clicked). Fails on 6dc0f19.

## Live check
`embark ... --play-now` (or a full embark): the run log ends `fort.intro: intro popup ("...") closed by Okay`, the fort shows no
popup, then `dfhack-run dfllm adopt`.
