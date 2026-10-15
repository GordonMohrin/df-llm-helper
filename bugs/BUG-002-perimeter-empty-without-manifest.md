# BUG-002 `perimeter` has no pieces on a fort without a manifest, PERIMETER_BROKEN cannot fire
Status: open
Severity: high (a destroyed perimeter wall goes unnoticed; Run 9 lost the shaft-head wall in a siege and the fort stayed open for two more sieges)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/seal.lua` (perimeter index and diff, FR-56)

## Expected
After a siege the kernel notices a destroyed wall, door or gate of the fort's boundary (PERIMETER_BROKEN, class A) and
queues the repair, also on a fort that was not built by the kernel (no fortcore manifest).

## Actual
```
$ python -m dfpilot cmd inspect what=perimeter
ok ... inspect: 0 perimeter pieces {"by":[],"diff":{"gone":[],"tick":146397551,"why":"retire"},"n":0,"pieces":[]}
```
The fort has hundreds of walls, doors and gates, a sealed shaft head and four drawbridges, but the perimeter list is empty,
so there is nothing to diff against. `inspect what=entrances` on the same save does find three real openings, so the
information exists but is not recorded as a perimeter.

## Cause (suspected)
Pieces come only from the manifest (`outer/inner` rooms, killbox). Without fortcore the list is empty by design.

## Fix proposal
When `inspect entrances` finds the fort sealed (or on a verb `perimeter.record`), store the walls, doors and gates that
border the sealed openings and every bridge as pieces; re-diff after each siege and on every `entrances` run. Fail open:
a fort with no manifest still gets the record.

Related: FR-56, FR-60, FR-54
