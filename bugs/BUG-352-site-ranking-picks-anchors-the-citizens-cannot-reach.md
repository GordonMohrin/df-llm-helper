# BUG-352 site ranking picks anchors the citizens cannot reach (another walk group, across the brook)
Status: fixed (offline, live-untested): the sites export carries the citizens' walk group, the ranking drops sites beyond
it and shows the group, the runner names an unreachable dig stage after 3 d. Open: a plain bp.cancel leaves the dig
designations the stage placed (about 1,580 stayed on z120-124 in the live case); the claim needs revealed tiles
Severity: critical
Found: 2026-11-04, Run 16c (i3, `runs/run-16c/FR-BUGS.md` "Fortcore Stufe 1 unausfuehrbar: DigChannel unreachable", run
r16c-w9-18-site97), main 8890b59
Module: `lua/dfllm/snapshot.lua`, `dfpilot/bp/sites.py`, `lua/dfllm/runner.lua`, `dfpilot/cli.py`, `dfpilot/wake.py`,
`dfpilot/schema.py`

## Actual
All 13 citizens stood in walk group 1562. `bp sites fortcore` ranked S3 [72,128,125] and S2 [58,128,125]: surface soil
floor in walk group 1, the other side of the brook. The fortcore project on [58,128,125] stood 30 d at s1.dig 0 %
(`inspect workload`: 'unreachable DigChannel'); [72,92,125] was in group 1562. After two bp.cancel and a new bp.place about
1,580 dig designations were left on z120-124 and the fort starved (food 0 d) because nothing could be dug. Nothing told the
player the dig was unreachable: status said `stalled`, the PROJECT_BLOCKED idle event came after 30 d.

## Root cause
- `dfpilot/bp/sites.py` `rank` (:217 on, `_fortcore` :1079): the ranking works on the snapshot's tile characters only; the
  snapshot (`snapshot.lua` `scan_span`) knew no walk group, so a revealed floor the citizens cannot walk to ranked like any
  other. `sites.Graph` (bp/topo.py) cannot tell: a brook is wadeable in its model, DF's groups are the truth.
- `runner.lua` knew the question only for a stuck seal (`Q.wait_why`, SEAL_STUCK); a dig stage got no such check, the
  idle rule (`Q.idle_scan`, `queue.idle_days` 30) was the first word.

## Fix
- snapshot.lua: a `sites` export reads `getWalkableGroup` for every walkable tile (the legend `. < > X r v + = H ^ w`) and
  writes `wg = {home, rows}`: `1` the citizens' group (`M.home_group`: the group most citizens stand in), `0` another
  group, `-` else. Other purposes and a world without groups carry no `wg`.
- schema.py SNAPSHOT: optional `wg` (rows of `[01-]*`, same shape as `rows`; `_snapshot_post` checks it); CONTRACTS appendix
  and §snapshot text.
- sites.py `reachable` (called by `rank` after the aquifer/water filters, before `near`/`at`): drops candidates whose
  anchor tile reads `0`; the others carry `walk` and `; walk group N` in `why`; ValueError ("all N candidate site(s) lie in a
  walk group the citizens cannot reach ...") when none is left. A tile without a read group claims nothing; a snapshot
  without `wg` is not filtered. RANK_V 3 (cached rankings are made again). `bp sites` prints `walk group N: the citizens'
  ...` (or says the group is unknown on an older snapshot).
- runner.lua `Q.reach_scan` (each PEACE run, after `Q.idle_scan`, own pcall): a dig stage without own progress for
  `queue.reach_days` (3) whose sampled pending tiles (<= 30, `snapshot.groups` near) lie in a known walk group no citizen
  (<= 50) stands in is announced once: kern.log warn and PROJECT_BLOCKED `why` `unreachable`, `unreach` = days, `cmd` =
  `bp.cancel`, `dfllm bp sites <tpl> --fresh`, `bp.place` again; the row says `unreachable N d: bp.cancel, place again`
  (state proj). A tile with no group, a hidden tile or any tile in a citizen group makes no claim. Nothing is cancelled.
- wake.py `unreach_hint`; fairplay/baseline `queue.reach_days` (1-60).

## Tests (fail on 8890b59)
tests/lua/test_snapshot_walkgroup.lua (2), tests/lua/test_bug352_unreachable.lua (2), tests/test_bug352_354_sitewg.py (8, 2 of them BUG-354).

## Live check
i3 after `dfllm reload`: `bp sites fortcore --fresh` lists only sites in the citizens' group, each `; walk group 1562`
(none of [58,128,125] / [72,128,125]); a fortcore placed beyond a brook by hand: PROJECT_BLOCKED `unreachable` after 3 d and
the status row `unreachable N d`. Check the sites export size (`snap/*.json` grows by one row set) and its scan time.
