# BUG-433 aqshaft refusal names no level or coordinate, an explicit column is not checked
Status: fixed (offline, live-untested)
Severity: medium (the player cannot tell why 1271 columns fail and cannot name one safely)
Found: 2026-11-05, Run 16c i3 Yawninggilt, main ad01acb (`runs/run-16c/FR-BUGS.md`, "OBS Fix-Runde 25": "Ablehnungsgrund mit Ebene/Koordinate nennen und p.x/p.y/p.top-Override erlauben")
Module: `dfpilot/bp/sites.py` (`_aqshaft`), `dfpilot/cmd.py` (`bp.place` explicit column)

## Actual
`bp sites aqshaft` printed only counts per reason. `bp.place tpl=aqshaft x= y= top=` emitted the shaft with no safety check at all (cmd.py explicit-column branch): no water distance,
no cavern, no rock-side test.

## Fix
- `_aqshaft` collects the first 3 examples per reason (rock: tile + level + char; cavern/warm: level; keep-out box; water: tile) into the error: `... an avoided cavern/warm level: N [x,y: cavern/warm level zL ...]`.
  The ranking also refuses open water within 3 tiles (WATER_KEEP, as `core_shaft`).
- `sites.check_column` / `cmd.column_checked`: `bp.place aqshaft` with p.x/p.y/p.top runs `shaft_why` (water >= 3, rock on the 4 sides, no cavern/warm level within the shaft or 1 below,
  keep-out boxes, top not water) and raises BpError with the reason. Without p.depth the column gets the refuge-level depth (BUG-432). No snapshot: not checked.

## Tests
`tests/bp/test_bug432_433_aqshaft_depth.py` (examples capped at 3, water 3 tiles beside, rock side, water top, `column_checked`).

## Live check
i3: `dfllm cmd bp.place '{"tpl":"aqshaft","site":"S1","p":{"x":20,"y":62,"top":127,"depth":N}}'` either places or refuses with the level/coordinate (place only with Gordon's OK near water).
