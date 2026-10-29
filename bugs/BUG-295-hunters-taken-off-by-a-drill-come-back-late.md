# BUG-295 hunters taken off by a drill come back only a month later
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/economy.lua` (tools at_once removal, M.drill_off_add, M.drill_restore, on.MODE)

## Actual
Run 15c Inkintense y376: WORK_DETAIL #1408/#1409 and #1492/#1493 `Hunters - ... (mode DRILL, target 0)`; they came back with `basis 1115` 30,000-50,000 ticks later (#1449, #1509) in the middle of the famine (`+ 0 hunters` in the gear line). Root cause: the drill's at-once removal (economy.lua tools, reason 'mode') is undone only by a later full economy run, which in a fort of 50 at timestream speed comes weeks later.

## Fix
The members a DRILL takes off (p.drill_off per detail) go back on their detail as soon as the mode is PEACE again (review: not RECOVERY; a drill that ended in a siege keeps the list until PEACE) (economy.on.MODE -> M.drill_restore, act.work_detail as the work details screen), WORK_DETAIL why `drill over`; a dead unit, a new soldier or a child stays off. An ALERT/SIEGE removal is unchanged (the usual tools pass decides).

## Tests
`tests/lua/test_fix10_economy.lua` (BUG-295). Fail on 05dc764.

## Live check
after the next drill: `dfllm events --type WORK_DETAIL` shows `Hunters + ... (drill over, back from the drill)` at the DRILL>PEACE tick; the gear line keeps `+ N hunters`.

Superseded in part by BUG-326: a drill and an alert no longer take hunters or fishers off; only a real siege does, and the list is restored as soon as the siege ends (RECOVERY too).
