# BUG-210 seal at=last walls the tile of a stale SIEGE_UNREADY instead of the current ways in
Status: fixed (offline, live-untested)
Severity: medium (the seal went to a shrub 34 days old and stalled; the real opening stayed open)
Found: 2026-10-29, live round 3, i-test3 "Earthboat"
Module: `dfpilot/cmd.py` (`last_entrances`, `current_openings`)

## Actual
`next` gave `dfllm cmd bp.place tpl=seal site=S1 at=last` while status named the opening 60,80,140; the seal went to 94,79,140 shrub,
the `ents` of a SIEGE_UNREADY of sum d43 (monthly by cadence). last_entrances and current_openings preferred the newest SIEGE_UNREADY
over the state's `ready.ents`, which readiness refreshes every run.

## Fix
`cmd.entrance_reading`: the newer of the newest SIEGE_UNREADY and the state's ready. The state wins once readiness has checked the
ways in (`ready.open >= 0`) and its tick is not older than the event; `open == 0` there means nothing is open. When the state's ents
begin the event's list it is the same reading and the event's longer list (up to 6) is kept. Both callers use it.

## Tests
`tests/test_bug209_213_cli.py` (last_entrances, current_openings), fail on bd27973.

## Live check
After a SIEGE_UNREADY, once `status` names other `ways in` tiles, `dfllm cmd bp.place tpl=seal site=S1 at=last` (its reply and bp file)
names the tiles of status, not the old event's.
