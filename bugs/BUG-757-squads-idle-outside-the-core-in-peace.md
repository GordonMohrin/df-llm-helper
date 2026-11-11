# BUG-757 squads stand outside the core in PEACE and nothing calls them back
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y440: `squad.sortie` against the predator in the fort: "target unreachable: 95,157,142 is on walk group 25, the squad on 331" (squad A outside), commands.log tick 177568186
Module: `lua/dfllm/military.lua` (`M.recall_pass`, `apply_squad`, `M.step`)

## Actual
Soldiers off their station stayed wherever they were (outside Kern+) as long as the posture gave no station order they could follow; the sortie and the siege postures then began with the squad on the wrong side.

## Root cause
`apply_squad` re-issues the posture's station on drift only; a squad with no station (training, off duty) or one it could not follow was never moved into the core in quiet PEACE.

## Fix
`M.recall_pass` (each military step, PEACE without a reflex hold): a squad with members outside Kern+ (not in the refuge) for `M.RECALL.after` (2400) ticks and no sortie, kill order, siege hold, feed release or stand-down gets a station order at the nearest Kern+ floor on its walk group (`kern_floor`, clear of the bridges); `apply_squad` uses it in place of the posture's station until every member is inside. A posture station that lies outside Kern+ on purpose is left alone. No Kern+ floor on the squad's walk group (a raised bridge, a wall or a door between): kern.log says so once per `M.RECALL.every`, no order. SIEGE, BREACH, ALERT or a reflex hold end it at once.

## Open
A squad cut off from the core by a raised bridge is told, not moved (gate owns the bridges). The grace period starts at the first look outside, not when the soldiers left.

## Tests
`tests/lua/test_bug757_recall.lua` (recall after the grace period with the order in Kern+; nobody outside or a reflex hold: nothing; the recall ends when they are back; a siege ends it). The station and siege traffic tests (`test_stations.lua`, `test_military*.lua`, `test_m3_sortie.lua`) pass unchanged.

## Live check
kern.log "squad X: N of its soldiers stand outside Kern+ ... called back to" in a quiet PEACE; `squad.sortie` no longer answers "squad on walk group" for a squad that was idle outside.
