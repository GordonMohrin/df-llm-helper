# BUG-602 `bp sites aqshaft` refuses every column "start on the floor of a placed room" while the fortcore waits for the aqshaft
Status: fixed (offline, live-untested)
Severity: high (the fort's core stays at 0 % for years: no Z4 floor, no farm site, no hospital, drink 0 days)
Found: 2026-11-09, Run 16c i3 Wallfree y372-y376 (40-143 candidates, project `s1.dig 0% BLOCKED:paused: aquifer: waits for an aqshaft`), Run 16a i1 Basementflew y441 (917 candidates "start on the floor of a placed room / beside placed projects")
Module: `dfpilot/cmd.py` (`rank_sites`, `_aq_open_sites`, `waiting_core`), `dfpilot/bp/sites.py` (`open_columns`, `RANK_V` 12)

## Actual
The fortcore placed with `p.aquifer=pass` digs nothing until a passed aqshaft exists (`lua/dfllm/runner.lua` `Q.aq_wait`, "aquifer: waits for an aqshaft pass"). `bp sites aqshaft` ranked only columns whose top is a public Z4 floor tile and then dropped each one whose top tile belongs to a placed room (`aq_top_ok`). A fort with no corridor yet has only the floors of its first placed rooms (tombs, beds, workshops), so every candidate was refused and the ranking said "all 40 candidate site(s) lie on or beside placed projects". `bp.place aqshaft` with a hand-named p.x/p.y/p.top worked, but nothing said so.

## Root cause
`dfpilot/cmd.py:416` (`_free_of_projects`, `aq_top_ok(top)` false for every owner that is not a fortcore / aqshaft / explore floor) over the candidate set of `bp/sites.py` `_aqshaft` (public Z4 floor only): when the fort has no core corridor, that set contains only placed-room floor. No ranking looked at open ground, nor at the column BUG-412 designs beside the waiting core.

## Fix
`rank_sites`: when the ranking raises for an `aqshaft` (no explicit column, no `where`), `_aq_open_sites` offers (1) the column `sites.core_shaft` puts beside the waiting fortcore's entrance (`waiting_core`: a fortcore stage 1 with `aquifer=pass` and no PROJECT_DONE; its own depth), then (2) `sites.open_columns`: open surface floor (`.` under `_`) on the citizens' walk group, nearest to the waiting fortcore (default the depot / embark centre), outside the core's own box (`CORE_BOX_R` 6), with `_aqshaft`'s rock / cavern / water / keep-out rules (`shaft_why`) and its depth rules (p.depth, else down to the core under the known aquifer). Each goes through the same `free` test (no clash with a placed project). The ranking's own reason is raised when nothing is left. `RANK_V` 12 (cached rankings are ranked again).

## Tests
`tests/test_bug602_606_f39.py` (4: the Wallfree world with every Z4 tile owned by a placed hospital and a waiting `aquifer=pass` core: S1 is the BUG-412 column beside the core and `bp.place S1` takes it; without the core shaft an open-ground column outside the core box; with no waiting core the column near the embark centre; a cavern level in every column still refuses)

## Live check
On a fort with a placed `fortcore aquifer=pass` waiting for an aqshaft and rooms placed before any corridor: `dfllm bp sites aqshaft --fresh` lists S1 with `BUG-602: shaft column ... beside the waiting fortcore`, `bp.place aqshaft S1` is accepted, the shaft digs (`AQ_PASS_DONE`) and `s1.dig` leaves BLOCKED:paused.
