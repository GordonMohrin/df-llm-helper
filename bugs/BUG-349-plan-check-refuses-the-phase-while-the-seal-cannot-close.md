# BUG-349 plan check refuses every phase raise while a seal that cannot be built holds the perimeter open
Status: fixed (offline, live-untested): the raise is waived after a year with the seal stuck, set aside or planned now;
propose keeps the phase its check refuses; the seal_stalled question says the bp.cancel is safe. Open: why the seal pieces
are never built (BUG-313/336 ground), the lost B2 lever
Severity: high
Found: 2026-11-04, Run 15 (Guildcleans, i2, `runs/run-15-guildcleans/FR-BUGS.md` "plan check: P5 wegen offenem Perimeter
abgelehnt, obwohl seal in s0 steht (y388)"), kernel main 14ff5a3
Module: `dfpilot/plan.py` (perimeter_gate, propose), `dfpilot/wake.py` (seal_stalled_hint), `lua/dfllm/runner.lua`
(Q.seal_escalate)

## Actual
Guildcleans y388-y390 (i2, r15-guildcleans-site97): `plan check` ERROR `perimeter: raising phase_target P3 -> P5 while the
perimeter is open 468 d` also with `{"tpl":"seal","site":"S1"}` first in seasons[0]; the player went back to P3, every year
since. state y390: `ready.fail [open_perimeter, levers:B2]`, `pd 1168`, `pw "levers lost: B2"`, `sched.seal {proj y374s1b0,
stuck 1, days 5508}`, proj `c1a1a485b71c19f201 seal.build 0 'set aside 192 d: stalled'`. cli.log: SIEGE_UNREADY
`perimeter OPEN 295 d (levers lost: B2)` (y388), `833 d (1 way in; levers ...)` (y389). events #8869 / #8870 DECISION_NEEDED
seal_stalled: `seal y374s1b0: hatch 77,100,123 open 5508 d` (cmd bp.cancel + bp.place at=refuge) and `seal
c1a1a485b71c19f201: wall 130,93,130 open 2332 d (no item)` (cmd bp.cancel + bp.place close=wall on the same tile). The player
did not dare to send them (#7282/#7283 earlier): nothing said they were safe.

Root cause plan.py perimeter_gate (was :1088): any raise from P2 on is an ERROR while R0 open_perimeter stands, however long
and whatever the fort did; nothing counts a seal that cannot be built. propose (was :2214) drafts the raise anyway, so its
own check refuses it. runner.lua Q.seal_escalate (was :3446) offers a wall again on a wall that waits for an item, and no how
says whether the bp.cancel is safe.

## Fix
- plan.perimeter_waiver: after `PERIMETER_WAIVE_D` (365) days of open_perimeter (state ready.pd) the raise is a warning
  when the fort did its part and the seal cannot close it: a seal stuck that long (fort.seals / state sched.seal) or set
  aside (state proj `set aside`), a seal among the plan's new builds due now, or nothing left a seal closes (pw only lost
  bridges/levers). The warning names the reason; max-pop stays held, the seal keeps running. A refusal says when the waiver
  comes (`after 365 d open (in N d) ...`).
- propose keeps phase_target at the current phase when perimeter_gate refuses the raise (note `FR-70: phase_target stays ...`;
  a sweep that came with the raise only is dropped).
- seal_stalled `how`: `recommended and safe (the cancel drops only the unbuilt hatch ...)` / `safe (...)` per branch; a wall
  waiting for an item (`no item`) gets no command (`no command helps: the wall waits for a building item ...`). The wake hint
  says `fix (safe: the bp.cancel drops only unbuilt pieces)` and what stays (the way in open, max-pop held, the phase may rise
  after 365 d). bp.cancel without undo removes only unbuilt pieces and their jobs (runner.lua cancel / Q.remove_unbuilt).
- No contract change (texts only).

## Tests (fail on 14ff5a3)
tests/test_bug349_351_plan.py (5 BUG-349 tests), tests/lua/test_bug336_seal_escalate.lua (+1 test, +safety checks).

## Live check
i2 Guildcleans: `dfllm plan check` with phase_target P5: `warn perimeter: open for N days (...) while seal y374s1b0 stuck
5508 d ...: raising phase_target P3 -> P5 is waived (BUG-349 ...)`, plan OK; PHASE P3 -> P4 once orders_rockstock passes.
The next seal_stalled for 130,93,130 without a command, its how `no command helps: the wall waits for a building item`.

## Review fix (merge16)
The waiver counted `ready.pd`, the age of the whole open spell, so an old seal stuck elsewhere waived a newly opened real way in
(a gate bridge destroyed today) at once. readiness now keeps the newest opening's tick (`st.nt`, persisted with `st.wn`, the
ways in counted): set when the spell begins, when the entrance check counts more ways in than before (0 -> 1 included; a drop
lowers the count, a later rise is new again) and when `pw` names a lost bridge or lever it did not name before. State
`ready.pn` = its days (<= pd; contract.lua, schema.py, CONTRACTS, appendix). plan.waive_age = min(pd, pn) (pd alone for an
older kernel) drives perimeter_waiver, the refusal's `(in N d)` and propose's note. Tests: tests/test_bug349_351_plan.py
`test_bug349_review_a_fresh_opening_is_not_waived_by_an_old_stuck_seal`, tests/lua/test_open_perimeter.lua `review fix
merge16` (both fail on cc65ee4). Live: after a bridge loss `ready.pn` restarts at 0 while `pd` keeps counting; plan check
refuses the raise until pn reaches 365.
