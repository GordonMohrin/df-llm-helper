# BUG-575 A mood slot the fort cannot fill in time waits silently until the insanity window
Status: fixed (offline, live-untested)
Severity: medium (decisions came too late; two Possessed moods died or nearly)
Found: 2026-11-06, Run 16a i1 y429 (Possessed 27099 `gems(rough) x1 none reachable`), Run 16c i3 y416-y417 (Possessed 26827 `boulders(hard) x2 none in the fort`), Run 16d i4 y377 (`cloth(silk) x1`)
Module: `lua/dfllm/care.lua` (`early_kind`, `mood_early`, `mood_report`)

## Actual
DECISION_NEEDED `mood_deadline` came 15 days before the insanity line or after the 2-day mood_material wait; until then nothing told the player that no work order can make a rough gem.

## Root cause
`mood_report` had no notion of a slot no fort chain can fill; every missing slot waited the same.

## Fix
`early_kind` classifies rough gem / hard stone without a care dig / silk with no web and no silk thread; `mood_early` sends DECISION_NEEDED `mood_deadline` with `early` 1 the first time, once per set of kinds per mood, with cmds `trade.want` (mood tokens), an explore `bp.place` for gem or stone, `inspect what=unit`.

## Tests
`tests/lua/test_bug573_575_mood_materials.lua`: rough-gem slot -> one early decision with the commands, not repeated; cut-gem slot with jeweler and rough gems -> none; silk with no web -> decision, with near webs -> none.

## Live check
A Possessed mood asking for a rough gem: DECISION_NEEDED `mood_deadline` `early` 1 at the first care report.
