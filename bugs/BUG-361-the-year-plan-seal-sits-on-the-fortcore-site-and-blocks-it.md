# BUG-361 the year-plan seal sits on the fortcore site and blocks it
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3), main 595364a
Module: `dfpilot/cmd.py`, `dfpilot/bp/sites.py`

## Actual
After the aquifer breach the year plan's seal y373s0b0 stood on the doors of the dead core's tunnel (75,91-93,124; also
105,77-79,124). A new fortcore beside it was refused: the ranked sites lay on or beside the seal's tiles.

## Cause
A `seal` is a FREE template (`Occupancy.clash` never refuses it) but its tiles keep later projects away. The fortcore
ranking (`cmd._free_of_projects`, `FREE_RANK_TPLS` = aqshaft only) did not look at placed projects, so the best ranked
sites, all clustered at the failed cores, were taken; `bp.place` found 0 free and the error did not say who held them.

## Fix
`FREE_RANK_TPLS` includes fortcore: the ranking keeps only the sites no placed project clashes with and fills the list from
free ones; when none is left the error names the holders: `all N candidate site(s) lie on or beside placed projects
(y373s0b0) (bp.cancel frees a parked one's tiles; a seal's cancel drops only its unbuilt pieces)`.

## Tests
tests/test_bug359_361_sites.py (`fortcore_ranking_keeps_only_sites_no_placed_project_holds`, `when_a_seal_holds_every_site...`).

## Live check
With a seal on the best site's tunnel `bp sites fortcore --fresh` lists other sites; with the seal over all, the error names it.
Open: a stalled seal of a dead core still blocks its own tiles until bp.cancel (its unbuilt pieces drop).
