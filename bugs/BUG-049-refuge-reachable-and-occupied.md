# BUG-049 The refuge was reachable for the enemy and occupied when the citizens came: nothing told whether it could be trusted
Status: fixed in 04043c3 (offline, live-untested): `seal.refuge_trust` (separation answer fresh, nothing open on the way, stair-head closer standing, nobody inside), state `alert.ref.tr`/`trw`, R0 `refuge_trust`, REFUGE_FAIL `hostile`/`at` with the position, sense counts the hostiles inside the refuge (`census.h.rin`, listed first); one open question for the live run (does an unforbidden hatch stop invaders?)
Severity: critical (Run 13 fell in y525 with the citizens finding Tiefe+ occupied)
Found: 2026-10-23, post-mortem Run 13 (Wheelsblows y525) cause 3: "Zuflucht unsicher: Tiefe+ war fuer Feinde erreichbar; beim Alarm fanden die Buerger sie besetzt" (REFUGE_FAIL "hostile inside")
Module: `lua/dfllm/seal.lua` (`hostile_in`, `rate`, `leave_why`, `alert_burrow`, `publish`, new `refuge_trust`), `lua/dfllm/sense.lua` (hostile scan), `lua/dfllm/readiness.lua`, `dfpilot/brief.py`

## Actual
Run 13, y525 summer d75: a snatcher, an intruder and an ambush came over the open O1 (BUG-048); B1, B2 and O1 had been lost since y507, the audit
failed from y507 to the end; at the alarm Tiefe+ already held enemies (REFUGE_FAIL "hostile inside"), 48 citizens died.

## Cause (from the base commit f17e2b3)
The choice logic already refused a burrow with a visible hostile in it (`seal.lua:2821` `rate`, `:2954` `leave_why`), but:
1. **The hostile may not be in the list.** `hostile_in` (`seal.lua:2761`) looks only at `census.h.list`, which keeps the 40 hostiles nearest to O1 (`sense.lua:37`
   `LIST_MAX`, sort key `:468`, cut `:494`). A refuge lies deep, far from O1 and outside the Z3/Z4 boxes that sort first, so with more than 40 hostiles in
   sight (a siege) one standing in Tiefe+ is cut from the list and the refuge looks empty. Test: `tests/lua/test_siege_sense.lua` "BUG-049 ... hostiles inside
   Tiefe+ are counted".
2. **The refusal has no place.** REFUGE_FAIL says `hostile inside` without where or how many, so the session could not tell a straggler at the stair from a
   band in the sleeping hall; the switch text said "a hostile inside". Test: `tests/lua/test_seal_refuge.lua` "REFUGE_FAIL hostile inside names where".
3. **Nothing says whether the refuge is trustworthy before the alarm.** `sep_of` returns nil for "not checked / changed since" and `rate` reads nil as fine
   (`:2821` `if s and s.exp`), the Python audit's `refuge_sep` and the kernel's own separation never meet, a stair head without its closer
   (`dfpilot/cmd.refuge_head`, BUG-031) is a plan-check finding only, and a separation answer from a stopped seal job is as good as a fresh one.
   Test: "the refuge is trusted only while ...".

## Fix (04043c3)
- **sense:** `census.h.rin` counts the visible hostiles on tiles of the manifest's refuge burrow; their list entries carry `rf = 1` and sort first (key -1),
  so the 40-entry cut never hides one.
- **seal:** `hostile_in` returns the count (the list's entries inside the burrow, or `h.rin` when larger) and the first position; `rate`/`leave_why` use
  the text `hostile inside at 7,6,5 (2 hostiles)`. REFUGE_FAIL carries `hostile` (count) and `at` (position); the REFUGE_SWITCH text and the status line say
  where. The choice already moved on the next ask (BREACH pick falls back to Kern+; confined citizens leave a refuge a hostile enters: REFUGE_SWITCH
  `breached`); the tests pin that.
- **Trust:** `seal.refuge_trust(K)` (public, CONTRACTS §7): ok only while (1) seal's separation answer exists, says no opening reaches it and is at most
  `CFG.sep_fresh` (35 days, more than the 28-day BFS cadence) old, (2) `readiness.refuge_audit` (the last Python audit's `refuge_sep`, worst case: a hatch is no
  barrier there) did not fail, (3) a closer stands on the stair head (manifest `refuge.anchor` + `stairs.civ`, the tile above the refuge level; a Hatch or Door built
  there), (4) no hostile is inside. State `alert.ref.tr` (1/0) and `trw` (first reason), `inspect refuge` `trust` (all reasons, `sep`, `age`, `audit`, `hatch`,
  `hostile`), status `refuge NOT TRUSTED: no hatch at 6,6,6`. Readiness R0 `refuge_trust` when the refuge is exposed, has no closer on its stair head or its
  separation answer is stale (not for a hostile inside: that is a fight; not for the audit: it has `refuge_sep`).

## Not decided offline (and what decides it)
- **Does an unforbidden hatch or door stop invaders in DF 53.16?** The kernel's flood counts every built door/hatch/bridge on the way as a closer (the lockdown forbids
  the entrance doors; nothing forbids the refuge's stair-head hatch); the worst-case audit counts none (CONTRACTS §9.10 `+`: never a barrier). If invaders open an
  unforbidden hatch cover, a hatch alone does not separate the refuge in a BREACH and the citizens must lock it behind them (a decision with the recall,
  BUG-035). Live data: in the next BREACH read `door_flags.forbidden` of the stair-head hatch (`dfllm cmd inspect '{"what":"refuge"}'` -> `trust.hatch.pos`, then the
  building at that tile) and whether any hostile ever stands in Tiefe+ while it is closed and not forbidden (`census.h.rin` > 0 with the hatch built: the log line
  of REFUGE_FAIL `at`). If it happens, the next step is locking that one hatch once the confined citizens are inside.
- **Whether the 40-entry cut really hid the Run 13 intruder.** Run 13 had few hostiles; cause 1 matters for the 58-goblin sieges. The REFUGE_FAIL `at` and the
  new `census.h.rin` answer it in the next live siege.

## Tests (each new one fails on f17e2b3)
`tests/lua/test_siege_sense.lua`, `tests/lua/test_seal_refuge.lua` (the position, the count behind a cut list, trust: hatch/audit/stale/exposed/hostile),
`tests/lua/test_readiness.lua` (R0 `refuge_trust`, `refuge_audit`), `tests/test_perimeter_escalation.py` (state and event fields, status line);
adjusted with reasons: the `alert.ref` golden and the REFUGE_SWITCH texts in `test_seal_refuge.lua` / `test_seal.lua`.

Related: BUG-018/019 (separated refuge), BUG-031 (stair-head hatch), BUG-048, FR-70.
