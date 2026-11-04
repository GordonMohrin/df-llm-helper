# BUG-350 bp files of a discarded timeline block every new explore site in the year plan
Status: fixed (offline, live-untested): projects of a discarded timeline only are no occupants. Open: live explore projects
that stall (slot yielded, set aside) keep their sites until bp.cancel (as before: no_site_hint names it)
Severity: medium
Found: 2026-11-04, Run 15c (Inkintense, i1, `runs/run-15c-inkintense/FR-BUGS.md` "Alte, haengende explore-Projekte
blockieren jede neue explore-Site im Jahresplan (y381)"), kernel main 14ff5a3
Module: `dfpilot/files.py` (discarded_projects), `dfpilot/cmd.py` (stale_bps, occupancy)

## Actual
Inkintense y381 (i1, r15c-inkintense-site97): `plan check` ERROR blueprint `site S1: only 0 free site(s) for explore depth=2
... taken by y378s0b1, y378s1b0, y378s2b0, y378s3b0 (+1)`; the plan had to drop explore (ore 0, METAL SHORT). The player read
them as hanging 0 % projects. events.jsonl: PROJECT_DONE for y378s0b1/s1b0/s2b0/s3b0 (#2315-#2400, ticks 152577927-152718528),
then #2422 TIMELINE_RESET `game clock jumped back (older save loaded): tick 152756256 -> 152409600`. kern.log after the
reload: `cavern check: y378s0b1 70,40 z128-126 gone: not dug yet; y378s1b0 ... gone` (the runner has no such projects), and
state proj names none of them. Their bp files (bp/y378s*.json, written before the reload) stayed.

Root cause cmd.py occupancy (was :479): every bp file is an occupant ("done projects stay in"), also one whose project the
loaded save never had: plan.done_projects already drops the discarded timeline's PROJECT_DONE (BUG-121), but nothing drops
its bp files, so the shafts that were never dug in the running game hold their sites for good.

## Fix
- files.discarded_projects: the project ids events name only in a discarded timeline (before a TIMELINE_RESET marker, later
  than its tick_neu) and never in the live one (cached per events file size/mtime; one timeline: none).
- cmd.stale_bps: those ids that state proj does not list, only while the list is complete (fewer than its 8 rows); occupancy
  leaves them out (bp.place, plan check/apply, explore_room, propose). The files stay where they are.
- On i1 now (read-only): stale_bps = y378s0b0, y378s0b1, y378s1b0, y378s2b0, y378s3b0 (the four plus the '+1' seal); i2-i4 none.

## Tests (fail on 14ff5a3)
tests/test_bug349_351_plan.py (3 BUG-350 tests).

## Live check
i1 Inkintense: `dfllm bp sites explore --fresh`, then `plan check` with explore@S1: no `taken by y378s...`.
