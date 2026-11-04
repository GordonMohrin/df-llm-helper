# BUG-360 bp sites fortcore says 'no water reachable' although a brook lies in the embark rectangle
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16b (i2 Ostgate, region1-site97), main 595364a
Module: `dfpilot/bp/sites.py`

## Actual
Embark scan: brook in the rectangle. `bp sites fortcore`: 'no water reachable, 0 water surface tiles'; status 'drink: no
still', drink 95 d.

## Cause
The sites snapshot (id c1a1a6dfffea206b41) is the fort pieces plus a margin, x38-114 y77-130 z127-132, and holds 4 water
tiles (z127). The brook lies at z130 x53-92 y1-40 (audit snapshot s150913717-3): outside the box. `_fortcore` ranked with
`water_bonus(None)` = -80 and the line `no water reachable` for every site alike, and it hid that the cause was the box.
A body of fewer than 8 tiles was never counted, even when the box cut it off at its border.

## Fix
`_no_water` names the case: `no water reachable (none revealed inside the snapshot box x.. y.. z..; a brook beyond it is
not seen: dfllm cmd snapshot purpose=sites with a bbox that covers the embark)`, `(only N water tile(s) ...: a puddle)`
or `(revealed water ... but no walking route to it)`. A body smaller than 8 tiles that touches the box's x/y border counts
(`_water_bodies(edge=True)`, fortcore only). The score is unchanged otherwise.

## Tests
tests/test_bug359_361_sites.py (`no_water_names_the_snapshot_box...`, `a_brook_the_box_cuts_off...`).

## Live check
`bp sites fortcore --fresh` on a map whose brook lies outside the default box: the reason line names the box.
Open: the default sites box is still the fort pieces plus margin (snapshot.lua `compose`), not the embark rectangle.
