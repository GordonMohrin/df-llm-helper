# BUG-603 `bp sites fortcore` ranks a site without a word about the aquifer it may dig into
Status: fixed (offline, live-untested)
Severity: medium (a core dig parks 30 days on AQ_HEAVY; the reason line said nothing)
Found: 2026-11-09, Run 16c i3 Wallfree y372 summer d3 (embark panel "light aquifer", `bp sites fortcore` S1 90,102,148 without `aquifer=pass`, the dig hit AQ_HEAVY #55 at z141, project parked 30 d, no auto plug; after `bp.cancel` the ranking said "no site clear of water")
Module: `dfpilot/bp/sites.py` (`_flooded`, `PASS_HINT`)

## Actual
The site's reason line ended in "no aquifer or water known on z...-z... (hidden rock is unknown)" or, for a known level, "aquifer at z127", and the score only dropped by `AQ_PENALTY`. Neither said the dig meets the level nor named `aquifer=pass`.

## Root cause
`dfpilot/bp/sites.py:2153` / `2157` (`_flooded` notes). The snapshot carries only the COUNT of revealed aquifer-flag tiles per level (`aqz`), no light / heavy kind, and nothing of the embark panel: a hidden aquifer cannot be seen by the ranking, only said.

## Fix
No ranking change (what the snapshot does not hold cannot be ranked; known levels are still penalized by `AQ_PENALTY` per level, a level a dig of ours met heavy still drops the site, BUG-484). The reason line now says it. A known level inside the dig: "aquifer at zN MEETS the dig (a heavy level stops it for 30 days, AQ_HEAVY; `bp sites fortcore aquifer=pass` puts the aqshaft first and the core under the aquifer)". None known: "(hidden rock is unknown; an embark whose panel shows an aquifer hides its levels until they are dug: ...)".

## Tests
`tests/test_bug602_606_f39.py::test_a_fortcore_site_says_when_its_dig_may_or_does_meet_an_aquifer`

## Live check
`dfllm bp sites fortcore --fresh` on an embark with an aquifer: the `why` of S1 names `aquifer=pass`.
