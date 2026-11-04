# BUG-351 plan propose drafts the stone dig bedrooms n=4 without a free site: an ERROR with nothing to insert
Status: fixed (offline, live-untested): a stone dig no free site takes is left out with a note. Open: a bedrooms phase
deliverable without a site still gets the check ERROR (its hint names the fortcore Z4 dig)
Severity: medium
Found: 2026-11-04, Run 15d (Drillchamber, i4, `runs/run-15d-drillchamber/FR-BUGS.md` "plan propose: bedrooms ERROR ohne
einfuegbares tpl-Objekt (y381)", STAND y381/y384 "bedrooms ohne freie Site entfernt"), kernel main 14ff5a3
Module: `dfpilot/plan.py` (fit_stone_dig, run, auto_plan)

## Actual
Drillchamber y381 and y384 (i4): the drafts carry `rock: 8 free boulders < 22 wanted (rock orders, walls): bedrooms@S1 n=4
first (a stone dig)`; `plan check`: `site S1: only 0 free site(s) for bedrooms n=4 (0 ranked); bedrooms rooms open from the
dug Z4 floor ...`. PLAYBOOK §5 step 2 (insert the object the ERROR names) did not apply; the player removed bedrooms by hand
both times (runs/run-15d-drillchamber/plan-y381.json, plan-y384.json show the drafts after that).

Root cause plan.py propose (was :2326): STONE_DIG is appended whenever rock_goal holds, without asking whether a bedrooms
site is free; the CLI propose (was :2919) fits explore (fit_explore) and core stages (fit_core) to the sites, not the stone dig.

## Fix
- plan.fit_stone_dig: the new STONE_DIG builds against the free bedrooms sites (rank_sites + explore_room, now with a tpl);
  those no free site takes are left out; the notes say `no bedrooms site for a stone dig` and `BUG-351: stone dig
  bedrooms@S1 n=4 left out: 0 free site(s) (...); ...` with what digs stone instead (the drafted explore/stockroom, else a
  stockroom or explore dig, trade.want stone, the fortcore Z4 floor). Called by `plan propose` and by auto_plan (follow).
- No snapshot or no bp package: nothing changes (as before).

## Tests (fail on 14ff5a3)
tests/test_bug349_351_plan.py (1 BUG-351 test).

## Live check
i4 Drillchamber with rock_goal and 0 bedrooms sites: `plan propose` prints `stone dig bedrooms@S1 n=4 left out: ...`, the
check has no bedrooms ERROR.
