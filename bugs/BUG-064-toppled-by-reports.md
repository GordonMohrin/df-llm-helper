# BUG-064 Bridges, levers and workshops vanish "without a cause": DF's "toppled by <dwarf>" reports were never read
Status: fixed in ee72cb1 (offline, live-untested; the exact announcement type and text are not decided offline)
Severity: high (a lost bridge is an open way; the culprit is a stressed citizen or a ghost nobody treated)
Found: Run 13 (Wheelsblows: B2 y507, O1 y509: BRIDGE_DESTROYED `bd=0`, PEACE) and Run 13/14 (19 reports "X toppled by
<dwarf>": a manager in a tantrum 5 times, a "Ghostly Mason"); notes 43 and 55 in bugs/RUN11-offene-bugs-und-FR.md
Module: `lua/dfllm/care.lua` (M.reports, M.on.REPORT, topple_*, M.toppled), `lua/dfllm/gate.lua` (gone_check),
`lua/dfllm/util/contract.lua` (C.REPORTS), `dfpilot/schema.py`

## Actual
`BRIDGE_DESTROYED ... lost 1x, 0 with building destroyers in sight` while the game's reports named the dwarf who toppled the
building: stressed citizens in a tantrum (the manager five times) and a ghost tore down workshops, levers and bridges.
The kernel saw only "no bridge on its footprint" (gate.lua:1318 at f17e2b3), the keepers asked a question nobody answers
(BUG-048) and nobody treated the culprit.

## Causes
1. No module listened to DF's announcement types `BUILDING_DESTROYED_OR_TOPPLED`, `BUILDING_TOPPLED_BY_GHOST` and the tantrum
   reports (`CITIZEN_TANTRUM`, `POSSESSED_TANTRUM`) (df-structures df.g_src.basics.xml; C.REPORTS lists only CITIZEN_TANTRUM
   as a routing hint, with no handler).
2. gate's loss history knows building destroyers only (`census.h.bd` within `LOST_BD` ticks, gate.lua:1257, `lose`), so any
   other loss reads "0 destroyers".

## Fix
- care listens (`M.reports`) and parses "<what> toppled by <who>" (also "destroyed by"); the culprit is looked up by name
  among the citizens, the fort's ghosts (`census.g`) and the death record (one match only; a ghost report with exactly one
  ghost in the census resolves to it); his `personality.stress` and stress category are read. BUILDING_TOPPLED (B): what, by,
  unit, ghost, stress, cat (0 worst), tantrum (a tantrum report named him before), pos, n (buildings since the last event);
  one event per culprit per `topple_every` (2,400 ticks). The newest 20 records are kept (`p.top`, persisted).
- `care.toppled(x, y, z)` (public): the newest record within `topple_win` (4,800 ticks) and `topple_r` (6) tiles of a position
  (a record without a position counts when its building is a bridge, gate or lever). gate's BRIDGE_DESTROYED asks it: the
  line reads `O1 destroyed (toppled by Kel Becordastot, stress category 0): no bridge ...`, the data carry `tby`, `tunit`,
  `tcat`, `tghost`.
- The culprit goes to the stress countermeasures (FR-74): the toppled buildings of the last 14 days are a stress source
  (`care.src.toppled`, named in STRESS_HIGH, the care line of the brief and `plan check`), a ghost culprit shows in GHOSTS
  (memorial slab), a living one is one of the stressed citizens the temple and tavern drafts answer.
- The perimeter keeper's own text (seal.lua, package A2's BUG-048) keeps counting losses with `bd`; reading BRIDGE_DESTROYED's
  `tby` there is a one-line follow-up after the merge (a loss with a named culprit is neither a destroyer loss nor a mystery).

## Not decided offline
- The announcement type and the exact text of the report. The code takes both toppled types and parses "toppled by" /
  "destroyed by" in the text; a ghost report without a name resolves only when the census names exactly one ghost. Live: a
  `BUILDING_TOPPLED` event for each "toppled by" report in the game log; if one is missing, `events.jsonl` has none and the
  report's `type` (`df.announcement_type[report.type]`) and text decide which pattern to add.

## Tests
`tests/lua/test_care_b3.lua` (BUG-064 group: culprit, stress, tantrum, ghost fallback, throttle and `n`, `care.toppled`
near/far/old, two dwarves of one name), `tests/lua/test_bridge_toppled.lua` (gate names the culprit, a ghost, the old text
without care), `tests/test_care_b3_files.py`. Each new test fails on f17e2b3.
