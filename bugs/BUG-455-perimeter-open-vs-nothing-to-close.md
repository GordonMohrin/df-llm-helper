# BUG-455 status 'PERIMETER OPEN, 3 ways in' while `bp.place tpl=seal` says 'nothing to close'
Status: fixed (offline, live-untested)
Severity: low (contradiction, R0 stays)
Found: 2026-11-05, Run 16c i3 Castletongs y374-y404 (`runs/run-16c/FR-BUGS.md` "BUG status: PERIMETER OPEN, aber seal sagt nothing to close")
Module: `dfpilot/cmd.py` (`seal_openings`)

## Actual
status: `PERIMETER OPEN 48 days: 3 ways in without door or bridge: 121,83,126 floor ...`; `bp.place tpl=seal at=last` refused `seal: nothing to close (...)`. BUG-374 fixed the stale-snapshot and the tile-less cases; what stayed is the case where every named way is closed on a newer snapshot or has a seal: the refusal said so but not that status counts the older entrance check.

## Fix
`seal_openings`: the count of the last entrance check (`ready.open`) is read for every `at=last`; when the entries are all closed on the newer snapshot / by a seal project it is added to the refusal ("status still counts N ways in: that is the last entrance check, the snapshot or a seal project is newer; the check runs again within a game day, `inspect what=entrances key=refresh` asks now"). The refusal stays SealClosed (done, not impossible).

## Tests
`tests/test_bug450_456_ops.py` (SealClosed with the status count).

## Live check
`seal at=last` right after a door was built: the refusal names the count and the refresh command; one game day later status and seal agree.
