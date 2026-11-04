# BUG-390 bp sites rank drops every site as an unreachable walk group while `inspect reach` says everything is reachable
Status: fixed (offline, live-untested): the home groups are re-read per exported row; the reach checks share one rule
Severity: high
Found: 2026-11-04, Run 16d (i4 Mazelanterns, `runs/run-16d/FR-BUGS.md`: "walk-group-Vergleich in bp.sites.rank ist falsch/veraltet", "Holzmangel: 5 FellTree unreachable")
Module: `lua/dfllm/snapshot.lua` (home_set/home_now, start, scan_row, groups), `lua/dfllm/economy.lua` (cv_reach, idle reasons)

## Actual
From y373 `bp.place workshops/dining/...` and `plan propose` were refused with "all 88 candidate site(s) lie in a walk group the citizens cannot
reach (they stand in walk group 23805)" while `inspect what=reach` listed all 23 citizens in group 23624 and every bed/drink/food/farm/well in it
(cut 0). No new building but seals for a year; 5 FellTree jobs counted "unreachable", 13 of 17 adults idle with "no reachable work", beds, doors
and coffins waited for wood.

## Root cause
Evidence: `E:/DF-test4/dfllm-runtime/r16d2-mazelanterns-site97/snap/*.json`: the nine sites exports of the last hours carry `wg.home` 2461, 2953,
3327, 3697, 4086, 4420, 4997, 5029 and then 464 (a restart), and all but the last have 7529-7531 of 7531 walkable tiles marked `'0'` (the last: 869
`'1'`). kern.log: "CUTOFF not confirmed ... ids renumbered while it ran". DFHack renumbers every walkable group whenever the map changes, also
while an export runs for minutes. `snapshot.lua` read the home id once at the start of the job (`start`, old :1282, `M.home_group()`) and compared
every tile read in the next minutes with `g == j.home` (`scan_span`, old :1361): after the first renumbering nothing equals that id, so every tile
reads `'0'` and `sites.reachable` (dfpilot/bp/sites.py:315) drops all candidates. `inspect reach` reads the groups live, so the two disagreed.
Two smaller causes of the same false "unreachable": the home group was only the biggest one (a fort split by a brook bridge has two big groups),
and `snapshot.groups(near)` answered the FIRST neighbour's group for a tile without one (a tree trunk, a dig wall), so a tree on the bank whose
first neighbour in the list lies across the brook read "far" (`economy.cv_reach`, old :7393, and the idle-reason pass, old :11439).

## Fix
- `snapshot.home_probes` (<= 40 citizen tiles at the start), `home_now(probes)` (snapshot.lua:1275): the groups of those tiles NOW -> (set, best);
  `scan_row` (:1417) re-reads them before every row, so ids and tiles of a row are from the same moment; `wg.home` is the last best group.
- `snapshot.home_set(K, ids)` (:1246): the citizens' groups = the biggest and every group with a fifth of the citizens read (two stranded dwarves
  are not a fort; a bridge-split fort counts both halves). Used by the export and by economy (`M.home_groups`, economy.lua:7406) via K.call.
- `snapshot.groups(K, pts, near, prefer)` (:513): with `prefer` ({[group]=true}) a tile without a group answers a neighbour's group inside `prefer`
  before the first one. `economy.cv_reach` and the idle-reason pass pass the citizens' groups: a tree is reachable when it touches them.
- `sites.reachable(.., focus)` (BUG-391): a ranking asked `--near/--at` a tile of another walk group is not filtered.

## Tests
tests/lua/test_bug390_reach.lua (3: ids renumbered after every frame of the export, home_set, trunk with prefer), tests/test_bug390_392_reach.py.

## Open
Live: a `bp sites` right after a restart with moving ids; `inspect workload` "unreachable FellTree n" should drop to the trees really beyond water.
