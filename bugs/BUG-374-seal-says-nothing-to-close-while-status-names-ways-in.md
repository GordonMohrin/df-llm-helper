# BUG-374 `seal at=last` says 'nothing to close' while status names open ways in
Status: fixed (offline, live-untested): the old snapshot no longer closes what the newer entrance check calls open; a counted way without a tile is no 'nothing to close'
Severity: medium
Found: 2026-11-04, Run 16d (i4 Plankscale, y374 winter, `runs/run-16d/FR-BUGS.md`), main 2fcd6e0
Module: `dfpilot/cmd.py` (entrance_reading, _seal_kind, seal_openings)

## Actual
i4 y374: status `PERIMETER OPEN 4 days: 3 ways in without door or bridge: 117,55,136 floor, 118,55,136, 119,55,136`;
`bp.place tpl=seal site=S1 at=last` -> `refused: nothing to close (the last entrance check names no open way in)`. The same
tiles stood open from y372 to y376 (events.jsonl SIEGE_UNREADY n=233, 370, 429, 623, 725, 1236); the only seal that closed
them is y376s0b0 (bp/y376s0b0.json). BUG-333 had made status, SIEGE_UNREADY, `inspect what=entrances` and `seal at=last`
read one list; it still differed.

## Root cause
Two ways the seal reading came out empty or closed while status (state ready.open / ready.ents) counted open ways:
- `cmd.py _seal_kind` (the snapshot's char wins over the entry): the `sites` snapshot (sites_snapshot prefers purpose
  `sites` over any newer one) can be many days older than the entrance check. A door or wall char on that old snapshot
  (`+`, `#`, `C` ...) read as 'closed' and dropped the opening (`left out ... (closed)`), although the check of today names
  the tile open (door destroyed, building gone). Only plants compared `geo.tick >= e["tick"]`.
- `cmd.py entrance_reading`: state `ready.ents` is written only with tiles (readiness.lua M.state) while `ready.open` is the
  count; a checked state with `open > 0` and no ents returned `[]` (the fallback to the SIEGE_UNREADY list applied only
  before readiness had checked), `seal_openings` found no entry and `_all_closed` read 'no entry' as 'closed'
  (SealClosed), which `plan apply` silently leaves out of the year.
Not reproduced against a live state (the i4 snapshot and state of y374 are gone, the kernel runs on); both paths are from the
code and the event log. The player's refusal text (`names no open way in`) matches the second path exactly (no notes, no
entries).

## Fix
- `_seal_kind`: an entry from the entrance check or a leak (not `at=`/`audit`) whose snapshot is more than SNAP_LAG (1200
  ticks, one readiness period) older than the check keeps its own kind when the snapshot shows a door or a wall there; a
  newer snapshot still closes it as before.
- `entrance_reading`: a checked state that counts ways (`open > 0`) without tiles takes the newest SIEGE_UNREADY list.
- `seal_openings`: with no entry at all and the state counting `open > 0`, the refusal is a BpError (not SealClosed) that
  says `status counts N ways in but no tile is on file` and the way out (`inspect what=entrances key=refresh`, or name the
  tiles). `plan apply` therefore no longer drops a seal while ways are open and unreadable.

## Tests
tests/test_bug374_376_seal_audit.py (3 for this bug, all fail on 2fcd6e0).

## Live check
Next time status names ways in and `seal at=last` is refused, the refusal names a reason. With a destroyed door on an old
`sites` snapshot the seal queues the tile.
