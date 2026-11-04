# BUG-342 gates fail in sieges: GATE_FAIL no_worker is a misread, lever pullers hold their own bridge
Status: partly fixed (offline, live-untested): the exact reason, the pullers in their room, review fix 2026-11-04: approach cancels no longer eat the deadline (bounded, DECISION_NEEDED gate_traffic), no_worker for foreign pulls, drop_own raises only; open: pullers that never reach their room, holding civilians off a footprint
Severity: high
Found: 2026-11-04, Run 15 (i3 Earthboat y387 spr, i4 Drillchamber y378 win / y376, i2 Guildcleans y378 sum)
Module: `lua/dfllm/gate.lua` (control: :1821 `r.stuck = 'no_worker'` for any pull without a worker, check_fail :1978; holders
at :1868 and :1772 count the bridge's own lever pullers)

## Actual
- i3 Earthboat y387 (siege with 5 trolls): `BREACH O1 not up at T+900`, GATE_FAIL #8834 `B2 not up after 1407 ticks (no_worker)`
  and #8912 `B2 not up after 913 ticks (no_worker)`, then the fort fell (92 -> 1). FR-BUGS: "Hebel-Bediener fest zuweisen (no_worker)".
- i4 Drillchamber: GATE_FAIL #3042 `O1 not up after 1201 ticks (no_worker)`, #4303 `B2 ... (no_worker)`.
- i2 Guildcleans y378: GATE_FAIL #2396 `B1 ... (blocked: citizen 26658 next to it)`; i3/i4: `B1: 15 pulls cancelled ...`.

## Evidence
- Every no_worker GATE_FAIL came 5-50 ticks after a fresh LEVER pull: i3 #8834 at 156072840, pull at 156072835; #8912 at
  156077581, pull at 156077531; i4 #3042 at 152765386, pull at 152765361; #4303 at 153572264, pull at 153572239.
- The pulls before were all cancelled for units walking toward the bridge, not for a missing worker: i3 kern.log
  156071433-156079784, 90 B2 pulls (lever 17806) in 8,400 ticks, `gate: B2 up pull cancelled: citizen 26729 2 tiles from it and
  walking toward it` (citizens to Tiefe+ up the stair 55,82 beside B2, soldiers to their station 55,80,135, animals); O1 in the
  same way (`O1 up pull cancelled: soldier 27054 3 tiles from it ...`). When not cancelled the pulls were taken at once
  (`O1 pull taken 16 ticks after queueing`). 118 pulls taken in i3, 114 of them by citizens who were no puller.
- Lever pullers holding their own bridge: fortcore's `dfllm-levers-b2` (u -2..-1, v 44..46) lies 1-3 tiles from B2's footprint
  (v 43); i3 Earthboat B2 levers 56,80 (1 tile) and 54,80 (3 tiles) from B2 at 57,81-83. `gate: lever pullers dfllm-levers-b2 =
  {21852,27079}` at 156076587, then `B2 up waits for citizen 27079 next to it` (156076707). Over all four Run 15 logs ~5 % of
  the holds and cancels are the bridge's own pullers (i3 kern.1.log 40 of 814 waits).
- Pullers seldom at the levers: 574 `let go ...:away` in i3 (76/106/76 in i1/i2/i4) against 4 pulls taken by a puller.

## Cause
1. gate.lua:1821 set `r.stuck = 'no_worker'` for every pull of ours not taken yet, also one queued a frame ago; check_fail
   (:1978) takes `FAIL_WHY[r.stuck]` first. A deadline that fell between a cancel and the next take read `no_worker`, while
   `r.nw` (pulls nobody took in NO_WORKER ticks) was 0. The pulls cancelled for walking units (BUG-251/311 approach) were
   counted nowhere.
2. The pre-pull footprint check (:1868) and the pending check (:1772, BUG-141 exempts the job's worker only) counted an
   assigned puller of the bridge's own lever room standing in that room beside the footprint as a unit holding the bridge.

## Fix
- A pull waiting for its worker is `queued` (not_up: 'a pull is queued, no worker yet'). GATE_FAIL `no_worker` only for
  pulls nobody took in NO_WORKER ticks; the text counts them and names the lever rooms (`lever pullers: dfllm-levers-b2 0 of 2
  at the levers`, or `no lever room`). New GATE_FAIL why `cancelled` when more pulls were cancelled for units walking toward
  the bridge than were left without a worker: `d.pulls` the count, `d.units` the last one, the text names him and his distance.
- An assigned puller of a room that holds a lever of the bridge, standing on a tile of that room and not on the footprint,
  holds the bridge no more than the job's own worker (BUG-141). On the footprint he holds it like anybody (BUG-310 unchanged);
  the walking-toward cancel (BUG-251/311) is unchanged for him too.

## Tests
`tests/lua/test_bug342_gate_workers.lua` (6; 4 fail on b35af6d: the puller in his room, `cancelled`, `queued`, the no_worker
text; the citizen beside the bridge outside any room and the puller on the footprint still hold it on both).

## Live check
Next siege or drill: GATE_FAIL reads `cancelled: N pulls cancelled for units walking toward it, the last ...` where the old code
said no_worker; a real `no_worker` names the pullers. With fortcore's B2 landing room: no `B2 up waits for citizen <puller> next
to it` for a puller in dfllm-levers-b2.

## Review fix (2026-11-04, merged into fix15-bridge with BUG-335)
- Approach-cancelled time (gate.lua:1845 `M.ap_credit`): a raise pull cancelled for a unit walking toward the bridge adds the
  ticks it stood queued to `r.held_sum` (not toward the deadline), for the first AP_CREDIT (8) such cancels of an epoch.
  Bounded: at the 8th DECISION_NEEDED `gate_traffic` (A; bridge, n, opts hold_civilians/reroute/lever, q names the last walker)
  asks once and the deadline runs again (then GATE_FAIL `cancelled`). No safe DF mechanism keeps civilians off a footprint (a
  burrow restricts where they go, not where they walk; traffic designations only weight the path), hence the question; the
  walking-toward cancel itself stays (safety first).
- gate.lua:2022 (the verifier's ~1907): a pending pull gate did not queue (the player's, or ours after a reload lost the
  runtime) without a worker is `queued`; `no_worker` only once nobody took that job in NO_WORKER ticks (`r.fj`), and the text
  then says `no_worker: a pull gate did not queue (job N) not taken in T ticks; lever pullers: ...` (old: '0 pull(s) not taken').
- drop_own (merge resolution): raises only (gate.lua:1931, :2042: a lowering crushes, a puller one tile away holds it as
  BUG-027 wants), and never drops a unit on the footprint or walking onto it (BUG-335 crossers).
- Our soldiers walking to their station over a bridge wanted up are re-stationed to its inner side (BUG-335 review), which
  removes one source of the cancels.

Tests: `tests/lua/test_bug342_gate_workers.lua` (+2: the puller beside O1 still holds a lowering; a puller in his room on a
path onto O1 holds the raise; the cancelled test checks DECISION_NEEDED gate_traffic once with n 8 before the GATE_FAIL),
`tests/lua/test_siege.lua` (the foreign pull's no_worker text). All fail on the merge base.

## Open
- The traffic itself (recall walking past B2 to the refuge stair, animals) still cancels the pulls; now bounded by the
  question, not solved. Holding the civilians back (an alert burrow without the footprint's approaches, a recall that waits
  for the raise) needs a live test of how DF paths burrow-restricted civilians.
- Pullers rarely reach their room (574 `away` in i3): under the civ alert DF seems to keep a citizen anywhere in the alert's
  burrows, so the personal lever-room burrow is no destination; not verifiable offline. A designated puller kept inside the
  burrow that holds the lever room, pre-positioning before raising and a retry with the nearest citizen need a live test
  (e.g. one puller per room kept from ALERT on, or a station-like hold).
- Related: BUG-013, BUG-027, BUG-141, BUG-251, BUG-310, BUG-311.
