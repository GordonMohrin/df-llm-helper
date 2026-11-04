# BUG-370 plan propose drafts builds that cannot be placed (unreachable walk group, open tunnel wall)
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-04, Run 16d (i4 Plankscale y378/y379, `runs/run-16d/FR-BUGS.md`), main 2fcd6e0
Module: `dfpilot/plan.py`

## Actual
`plan propose` y378 drafted explore@S1 in s2/s3 and `plan check` answered ERROR 'all 138 candidate sites lie in a walk group
the citizens cannot reach'; y379 the same for explore and bedrooms n=4; gallery_o1 was drafted at a place where `the tunnel's
east wall is open at 80,74,137`. The player struck the builds from the year plan by hand every year.

## Root cause
Round 17 (BUG-352) put the citizens' walk group into the sites snapshot and `bp.sites.reachable` raises when every candidate
lies beyond (sites.py:313). `propose` knew nothing of it: `fit_explore` (plan.py) treats any BpError but 'avoided level' as
'nothing to fit' (returns None, the build stays), and no fit existed for the other room templates or for
`defense.site_problem` (gallery_o1). The only judge was the draft's own `check` + `_dry_place`, after the file was written.

## Fix
`plan.fit_placeable(save, doc, prev)` (run by `plan propose`, and by the follow auto plan next to `fit_stone_dig`): places the
new builds in plan order as `apply` would (shared occupancy, `place` with the sites snapshot) and leaves out each build whose
placement raises: all sites in another walk group, a site whose rock/tunnel does not fit, no free site. The draft's notes and
the CLI say `BUG-370: explore@S1 left out: <reason>`. fortcore, seal and traps are not judged (their own fits decide); a
`same` build whose base is not placed here is skipped. The walk-group filter itself is `sites.reachable` (round 17), now
applied at draft time instead of at the check.

## Open
The 'which dig joins the walk groups' hint the player asked for is not produced; a build left out is not drafted again
until the snapshot shows a reachable site (propose runs the fit on every draft).

## Tests
tests/test_bug368_370_depot_fresh_walk.py (drops the unreachable explore and the gallery with the open wall, leaves fortcore /
seal / a `same` build without base alone, the checked draft has no walk-group ERROR after the fit and has one before).

## Live check
i4-like (a core enclosed from the citizens' group): `plan propose` prints `BUG-370: explore@S1 left out: ... walk group ...`,
`plan check` OK, no hand edit.
