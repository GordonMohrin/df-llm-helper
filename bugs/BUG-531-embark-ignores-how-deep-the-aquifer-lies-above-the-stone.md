# BUG-531 The embark check does not ask whether a core can be dug under the aquifer
Status: fixed (offline, live-untested)
Severity: high (a fort without a core falls at the first big siege: Basementflew y406 99 -> 31)
Found: 2026-11-06, Run 16a i1 Basementflew (`runs/run-16a/STAND.md` y405 "Aquifer z114-z127 durchgehend, heavy z116/120/123: Kern unter Aquifer nicht moeglich"; panel 'light' aquifer, soil 'some')
Module: `tools/embark/checklist.lua` (`evaluate`, `C.DEFAULT`), `tools/embark/rules.json`, `tools/embark/README.md`

## Actual
The embark panel names a class (light). BUG-465 added an estimated reach (soil levels + span of the class: light 4), shown in the stone item but only soil levels judged: a site with 14 aquifer levels and heavy layers (Basementflew: soil 'some' + 'light') passed as a plain `aquifer: warn` like any light aquifer, and the fort could neither dig a core under it nor pass it. (Heavy tiles of the hovered rectangle already merge into class heavy = fail; the heavy layers of this site lay inside a 'light' panel and could not be seen.)

## Root cause
`checklist.lua` judged the aquifer by class only (`tiered('aquifer', ...)`: none pass, light warn); the reach of BUG-465 only fed the stone item (soil levels alone decided the fail) and the ranking.

## Fix
After the stone block `evaluate` computes the core reach = soil levels + `core_span` of the class (the WORST span seen: light 8, varied 10, heavy 14; BUG-465's `aquifer_span` stays the usual one for the stone item) and compares it with `core_reach_warn` (9) and `core_reach_max` (13) (`C.DEFAULT`, `rules.json`): above the first the aquifer item warns "the core must go under the aquifer: up to N levels to the hard stone below it (S soil + up to A of the light aquifer) ... the first aqshaft shows the real span", above the second it FAILS "no core below the aquifer within reach ..." (still acceptable with `--accept aquifer --reason`, the player's trade-off). A site whose stone item fails already (deep soil) is not failed twice. `out.core_reach` carries the figure; the item moves between `fails` / `warns` once. README row of the aquifer criterion.
With the default limits this is a WARNING for a light aquifer over 'some' soil (3 + 8 = 11) or shallow sand / clay (10) and silent for 'little' soil (9); the fail only triggers with stricter rules (`core_reach_max`) because varied / heavy aquifers and deep soil fail already. The panel gives a class, not the real span: the numbers are the worst observed, not a measurement.

## Tests
`tests/lua/test_embark_bug531.lua` (5: a near core stays a plain warning, the Basementflew case warns once with the numbers, a stricter maximum fails once and stays acceptable, a stone fail is not doubled and no aquifer is not checked, rules.json equals the defaults).

## Live check
`python tools/embark/embark.py scan <wx,wy> --hover` on a world tile with deep soil and a light/varied aquifer: the aquifer item names `the core must go under the aquifer: up to 11 levels ...`.
