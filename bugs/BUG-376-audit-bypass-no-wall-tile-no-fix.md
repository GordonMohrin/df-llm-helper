# BUG-376 audit bypass 'no wall tile on the route' names neither a fix nor a waiver
Status: fixed (offline, live-untested): the finding names what the route passes; status and plan check give a fix or the waiver
Severity: low
Found: 2026-11-04, Run 16d (i4, `bypass: edge->Z3/Z4 avoids the trap hall (reaches ...)` y376-y380) and Run 16b (i2, R0 for years)
Module: `dfpilot/bp/topo.py` (route_via), `dfpilot/cmd.py` (route_advice), `dfpilot/brief.py`, `dfpilot/plan.py`, `lua/dfllm/readiness.lua`

## Actual
`bypass: edge->Z3/Z4 avoids the trap hall (reaches 113,104,13` (cut at 60) in every audit of i4 from y376; status said `no wall
tile on that route: dfllm cmd inspect what=entrances`, plan check `no wall tile on the route (stairs, doors or bridges); look at
it ... and close it`. inspect names the entrances, not the route; nothing could be placed.

## Root cause
`topo.choke_pick` proposes a wall only on a floor tile or a climbed ramp of the foreign part of the route. A route that
passes only stairs, doors or bridges (an explore shaft, a door, a bridge) has none, and the finding fell back to a text without
tile or kind; brief.py/plan.py had nothing to say but 'look at it'.

## Fix
- `topo.route_via`: the finding is `bypass: via stair|door|bridge x,y,z -> X,Y,Z` (also `refuge: on the attack path, via ...`),
  the tile nearest the target on the foreign part; the old text stays where the target lies on the attack side itself. It is
  under 60 characters, so the kernel's cut keeps it. The wall form (`wall x,y,z floor`) is unchanged: seal at=audit and every
  regex read what they read.
- `cmd.route_advice`: a door -> remove the building by hand, then `seal at="x,y,z floor wall"`; a stair -> no wall can stand
  on a stair and the audit counts a hatch open, so no piece closes it; a bridge -> rebuild as wall + door. Each ends in
  `WAIVED`: plan check only warns (audit_gate returns no error for a route without a wall), R0 `bypass` stays until the audit
  reads another route. Used by `status` (brief.line_unready) and `plan check` (audit_gate); readiness' wake line says
  `placeable fix or waiver in status`.
The audit verdict itself is unchanged (a waiver inside the model would change the gate; not done).

## Tests
tests/test_bug374_376_seal_audit.py (4, fail on 2fcd6e0), tests/lua/test_readiness.lua (the via route in the wake line).

## Live check
After a kernel reload and `dfllm audit` in a fort whose bypass runs through a stair/door: the finding reads `bypass: via stair
x,y,z -> X,Y,Z`; `dfllm status` shows the advice instead of `inspect what=entrances`.
