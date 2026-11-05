# BUG-453 Our own explore shaft makes an R0 bypass
Status: fixed (offline, live-untested)
Severity: medium (R0 bypass, no seal piece can close a stair)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y384 winter (`runs/run-16a/FR-BUGS.md` "OBS Explore-Schacht erzeugt Umgehung")
Module: `dfpilot/bp/sites.py` (`explore_rects`), `dfpilot/cmd.py` (`route_advice`)

## Actual
After explore@S1 the audit reads `bypass`/audit_fail: "route passes the stair 40,86,138: a wall cannot stand on a stair ... no seal piece closes it". The shaft (anchor on a Z4 floor at z138, depth 12 to z126, tunnels every 3 levels, 6 tiles) opened a way from outside to the core past the trap hall.

## Root cause
`sites.explore_rects` checked the tunnel levels with a one-tile ring: an arm may end next to a revealed opening, a cavern edge or water ("no revealed open" only inside the ring); the audit counts a hatch open and a wall cannot stand on a stair, so the route over the shaft's stair has no closable tile.

## Fix
- The levels with side tunnels grow their check rect by `EXPLORE_RING` (3) tiles all round (the plain shaft levels keep one): an arm never ends within three tiles of a revealed floor, ramp, water or mark. The ranking drops the anchors whose tunnels would come that close.
- `route_advice` for a stair bypass names the explore shaft ("its tunnels broke out below: bp.cancel that explore, place none on that side again") besides the waiver.

## Tests
`tests/test_bug450_456_ops.py` (rect rings per level, advice).

## Live check
`dfllm bp sites explore --fresh` ranks fewer anchors near the hill face; an existing bypass is not repaired by this (cancel the explore, WAIVED).
Open risk: tiles that are still unknown beyond the ring; the sealed route needs a tunnel floor tile that a wall can take.
