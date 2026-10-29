# BUG-208 a set of were-forms that grows inside the kill gate never gets its curse_kill
Status: fixed (offline, live-untested)
Severity: medium (a third were-form went without a kill question for four moons; RULES section 1: the player decides)
Found: 2026-10-29, live test round 3 (BUG-174c re-check), kernel bd27973
Module: `lua/dfllm/curse.lua` (`M.finish`, `M.kill_question`)

## Actual
Wave 1 (42328, 42361) gave DECISION_NEEDED curse_kill '2 were-form unit(s) in the fort'. Wave 2 (42306) came 137 ticks
later; its TRANSFORM went out 830 ticks after wave 1 ('3 were-form in the fort now'), but no curse_kill followed for ~180
game days. `kill_question` was called only from `emit_transform`, and its gate `CAD.due(cur.ev.kill, .., {ticks =
curse_every * 4})` (2400 ticks) refused the grown set; nothing asked again.

## Fix
`M.finish` (care's run end and the daily `watch`) calls `M.kill_question` whenever a were-form is known and no TRANSFORM
waits in the queue (the question never comes before its TRANSFORM). `CAD.due` still allows one question per set and per
2400 ticks, so an unchanged set is not asked again.

## Tests
`tests/lua/test_bug207_208_curse.lua` BUG-208 (the grown set; one unchanged set is asked once), the first fails on bd27973.

## Live check
Two were-forms, then a third within 2400 ticks of the first curse_kill: within a game day after the gate opens
`python -m dfpilot events` shows a second `DECISION_NEEDED curse_kill: 3 were-form unit(s) ...`, and no third one while the
set stays the same; `inspect persist` `m.care.cur.ev.kill.ids` holds all three ids.
