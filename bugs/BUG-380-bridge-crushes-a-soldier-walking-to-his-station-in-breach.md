# BUG-380 a bridge raise crushes a soldier walking to his station (BREACH, no hostile in sight)
Status: fixed (offline, live-untested): a raise in a fight lets walkers go only with a hostile in sight within 30 tiles; stations count bridges on the levels beside them
Severity: high
Found: 2026-11-04, Run 16d (i4 Woodmill, the fort that fell): events #2699 GATE_CRUSH_RISK and #2700 BRIDGE_CRUSH, tick 153579422-598
Module: `lua/dfllm/gate.lua` (holders), `lua/dfllm/stations.lua` (sdist, blockers, relocate)

## Actual
Mode BREACH, `BREACH: 0 visible, 0 lost`. Squads 99-101 (12 soldiers, 3 of them on station 1827 ticks into the BREACH) walked to
their stations 76,114..115,134, below the core stair 78,115 two tiles behind B2 (footprint 77..79,113,137). B1/O1/B2 were pulled
about ten times in 1500 ticks (`B1 up: 8 pulls cancelled for units walking toward it`); at 153579422 the pull of B2 went out, B2
moved at 153579498 and soldier 26395, 9 tiles out at the time (`walking onto it in 2 steps` of B1, then B2), stood on the
footprint at 153579595: `B2 moving up with soldier 26395 on the footprint at 78,113,137`, crushed at 153579598.

## Root cause
- `gate.lua` holders (was l.1393): the hotfix 571f58f let every walker farther than PATH_SIEGE (6) steps go in SIEGE and BREACH
  to end the stream that held B1 down for good. It did so with or without a hostile. The lever moves the bridge when the puller
  is done and the bridge moves ~100 ticks (a dwarf covers 11 tiles): a walker 7..17 steps out is on the footprint before it
  stops. With no hostile in sight nothing was worth that risk. (The raise was not 'forced': a forced raise needs a hostile within
  force_near, `hostile_dist`, and there was none; the forced branch still holds only units ON the footprint.)
- `stations.lua` S.dist: a footprint on another z never held a station. stations.b2 76,115,134 lay 2 tiles (x/y) from the
  footprint on a level three below it, with the core stair between them: military kept it, the squads crossed B2 to and from it
  all the time (and `restation` found the soldiers 'passing' on z137 and the station on z134: no match).

## Fix
- gate.lua: `M.HURRY_NEAR` (30, siege's own raise distance): in SIEGE/BREACH a raise lets walkers farther than PATH_SIEGE steps go
  only while a visible hostile is within HURRY_NEAR tiles of that bridge (`hostile_dist`: sense's near_bridge, 3-D); with none (or a
  stale census) every walker whose path enters the footprint within PATH_STEPS (20) holds it, as before the hotfix. A hostile
  within force_near still holds only for units on the footprint.
- stations.lua: `S.sdist` / `S.ZREACH` (3): `blockers` and `relocate` count a footprint up to 3 levels above or below by the x/y
  distance (clearance unchanged: margin + spread = more than 2 tiles). `S.dist` (the footprint itself) is unchanged.

## Tests
tests/lua/test_bug380_siege_traffic.lua (3: a squad walks to stations beyond a bridge, citizens stream over it, BREACH without a
hostile and SIEGE with an army approaching / 25 tiles away; nobody on a footprint when a bridge moves AND the bridge up before the
army arrives and before T+900; (1) and (2) fail on ec9bd8e: a citizen crushed), tests/lua/test_stations.lua (2, fail on ec9bd8e),
tests/lua/test_siege.lua (the hotfix stream test now with the army 25 tiles away).

## Live check
In a BREACH without a visible hostile `kern.log` shows `B2 up still waits for ... walking onto it in 8..20 steps` and the
pull goes out when the stream is gone; no `GATE_CRUSH_RISK` / `BRIDGE_CRUSH`. With an army in sight inside 30 tiles walkers
beyond 6 steps are let go as before (the stream does not keep B1 down: no `B1 not up at T+900`). A station 2 tiles from a footprint
on another level is moved (`STATION_MOVED why bridge`). Open: a hostile within 30 tiles with a stream over the bridge still
accepts walkers 7+ steps out (the hotfix); soldiers still cross a bridge to a station on its inner side while it is down.

## Review fix (merge20)
Two review findings on `holders()` (gate.lua) in a SIEGE/BREACH raise:
- CRITICAL crush: with a visible hostile 11..30 tiles away the walkers 7..20 steps out were let go, but a walker covers ~11 tiles in the
  ~100 ticks the bridge moves (9 ticks per tile): soldier 26395 died so.
- MAJOR breach: with no hostile in sight, a stale census or a hostile beyond 30 tiles every walker within 20 steps held the raise, so a
  steady stream kept B1 down until GATE_FAIL at T+900 (the round-15 disaster).
The rule is now on time, not on the hostile's distance (`M.STEP_TICKS` 9, `M.CROSS_REACH` 13 = the ~11 tiles of the move + margin;
`PATH_SIEGE` and `HURRY_NEAR` are gone):
- a walker holds the raise iff he can be on the footprint before the bridge has finished moving: his path enters it within CROSS_REACH
  steps. Walkers farther out never hold (they cannot get there in time), with a hostile or without. Units ON the footprint always
  hold (BUG-310); a forced raise (hostile within force_near) still holds only for them.
- deadline escape (`M.CROSS_HELD` 0.5, `M.CROSS_ESCAPE` 2): once a raise has been held for half the DEADLINE (`held_sum` + the running
  hold) only units on the footprint or within 2 steps hold it; kern.log `gate: B2 raise held N ticks: only units on the footprint or
  within 2 steps hold it now` (once per epoch, `r.esc`). Accepted risk: a unit 3..13 steps out then walks onto the moving bridge; the
  alternative was GATE_FAIL.
Tests: tests/lua/test_bug380_siege_traffic.lua (4 more: (4) stream 8..20 steps out without a hostile, (5) the same with a hostile
parked 20 tiles away, (6) BREACH, hostile at 20 tiles, soldier 9 steps out walks onto it, (7) a queue within 5 steps for good ->
the escape raises before T+900; every test asserts no crush AND up before T+900; (1), (3), (4), (5), (7) fail on the merge20 code).
Test (6) passes on the old code too (the parked army is not in the census of the siege world); it guards the new rule only.
The existing tests: (1) citizens 230 instead of 170 ticks apart (a stream with no gap of the pull's ~70 ticks cannot be raised onto
without the escape), (3) no longer expects B1 before the last citizen; test_merge15_gate_review.lua walker path at step 2 (the walker
at step 6 is let go by the escape). Live check: a stream over a bridge in a BREACH: the raise goes out in the first gap, or after
~450 held ticks with the escape line in kern.log; never `B1 not up at T+900` for walkers only.

