# BUG-193 `bp.place aqshaft site=S1 p={x,y,top}` refused: "bp.sites.rank(aqshaft): no ranking"
Status: fixed (offline, live-untested)
Severity: medium (the documented form fails; workaround site `A<x>_<y>_<z>_0`)
Found: 2026-10-29, FR-95 live test 1, instance i4 (kernel b805745)
Module: `dfpilot/cmd.py` (`place`, new `own_anchor`)

## Actual
`dfllm cmd bp.place '{"tpl":"aqshaft","site":"S1","p":{"x":56,"y":56,"top":129}}'` -> `bp.sites.rank(aqshaft): no ranking`.
`cmd.place` resolved an S label through the ranking before `bp.emit` applied `anchor_of_params` (dfpilot/bp/sites.py:220 raises).

## Fix
`cmd.own_anchor(tpl, params)`: the anchor a template takes from its own params (`anchor_of_params`; a ValueError becomes a
BpError, e.g. only some of x, y, top). `place` uses it for an S label without ranking (the occupancy clash is still checked);
`A<x>_<y>_<z>_<rot>` and `same` are unchanged; without the column an S label still gets rank's "no ranking" answer.

## Tests
`tests/test_bug193_aqshaft_place.py` (S1 with p.x/p.y/p.top, the A label, resolve_site, partial params, overlap), fails on 9da84d6.

## Live check
i4: `dfllm cmd bp.place '{"tpl":"aqshaft","site":"S1","p":{"x":X,"y":Y,"top":Z}}'` is accepted and `bp/<id>.json` has anchor [X,Y,Z].
