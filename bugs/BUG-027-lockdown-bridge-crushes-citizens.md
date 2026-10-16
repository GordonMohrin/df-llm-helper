# BUG-027 the lockdown raises bridge 17880 on top of citizens: two deaths on its footprint
Status: fixed in the core: occupancy check before every pull (1ded2eb), alert-first order, waiting-aware deadline and backup lever (Claude, 2026-10-16; offline, live-untested); BRIDGE_CRUSH follows
Severity: critical (7 deaths so far, incl. a baby; every invasion costs citizens to our own gate)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97), y417 autumn and y418 summer, Claude playing
Module: `lua/dfllm/gate.lua`, `lua/dfllm/siege.lua` (T0..T0+450: O1/B1 up "as soon as nobody (soldiers excluded) is outside, or at T+450")

## Actual
Bridge 17880 at (128,127..129,122), raised by the lockdown. Both deaths lie on its footprint:
```
y417 aut  #4895 DEATH citizen 26535 (Recruit) died: unknown (not found yet, missing in the unit list)   pos 128,127,122, later a ghost (no_body)
y418 sum  #5163 DEATH citizen 26099 (Miner) died: unknown (not found yet, missing in the unit list)     pos 128,129,122, flags2.killed = true
```
No combat report in `world.status.reports`; the enemy (a goblin snatcher / one armed intruder) was far away (7,191,127). The corridor x=128 joins the core and the workshops, so miners and soldiers cross it all the time.

### Update y419 spring d30 (siege of 48 goblins)
Within minutes 11 citizens died (pop 120 -> 109, soldiers 21 -> 16). Seven deaths in total lie on bridge footprints: 26535 (128,127,122, y417), 26099 (128,129,122, y418), then y419: 26098 Planter (128,127,122), 26463 Recruit (128,128,122), 26818 Recruit (128,129,122), 27608 BABY (128,127,122), 26666 Recruit (101,129,122, O1 footprint). The other four (3 children, 1 recruit at (94..97,123..129,123..124) and (42,125,127)) were outside when the siege came.
Same siege: GATE_FAIL B1 and O1 'not up after 900 ticks', BREACH 'O1 not up at T+900', REFUGE_FAIL Tiefe+ (63 tiles < 109, beds 8 < 28), the 60 s default lockdown. Later all three gates were up and `inspect entrances` said sealed.

## Expected
Before every raise/lower of a bridge the gate checks the footprint for living units (citizens, soldiers, animals, visitors) and waits; only a real threat (hostile within N tiles of the gate) justifies raising anyway, and that is reported. The death cause "bridge" is recognised (position inside a bridge footprint, killed flag, no combat report) and raised as a class A event.

## Fix proposal
1. gate: footprint occupancy check (`dfhack.buildings.getBuildingAt`/unit positions in x1..x2,y1..y2,z) before every pull; soldiers are not exempt.
2. DEATH classification `BRIDGE_CRUSH` (A).
3. Mock test: a unit on the footprint -> no raise, event.

Related: BUG-013/BUG-014 (lever pulls under the civ alert), POSTMORTEM-run9-test-siege (gates 0 of 4 up)

## Cause
In SIEGE/BREACH (`FORCE_MODES`) the gate treated a raise as forced, and three rules followed from it (gate.lua before the fix):
1. **No pending re-check of a raise.** A pending pull was cancelled for a citizen on the footprint only when it was a
   lowering (`dir == 'down'`), and the MARGIN cancel (live L4) explicitly skipped `dir == 'up' and FORCE_MODES[mode]`.
   The lever moves the bridge when the puller finishes the job (live L2/L3: 150-250 ticks after queueing), so a raise
   queued while the corridor was momentarily clear was carried out onto whoever walked on in the meantime.
2. **No margin at queue time.** `near = forced and 0`: the one-tile ring (the L4 lesson: the commander stepped back on)
   was ignored for SIEGE/BREACH raises.
3. **Forced after 300 ticks.** With a citizen on the footprint the raise waited `BLOCK_WAIT` (300) ticks and then went
   ahead regardless (`gate: raising %s with a citizen on it after %d ticks`), without looking at where the enemy was.
   The existing test `a soldier on the B1 footprint delays its raise by 300 ticks in a SIEGE` encoded this rule.

siege wants B1 up at T0 when nobody (soldiers excluded) is outside, when a hostile is within 10 tiles, or at T+450 at the
latest; that only sets the want. Whether the footprint is clear is gate's job, and in SIEGE gate did not hold it. On a
corridor bridge with steady traffic (the miner, soldiers walking to their stations) rule 1 alone makes a crush likely;
rule 3 makes it certain once the footprint stays busy for 300 ticks. The census was not the problem: `census.u.ids`
holds every citizen and resident (`getCitizens(false, true)`), soldiers and recruits included.
The live kern.log can tell 1 from 3: rule 3 left `gate: raising B1 with a citizen on it after N ticks` (warn).

Taking `gates` out of `config/reflex.json` ARRIVAL/INTRUDER would **not** have helped: siege raises B1 itself in SIEGE.

## Trade-off (forced raise)
Raising a drawbridge onto a unit kills it (live L4: death cause DRAWBRIDGE; Run 10: two deaths). Not raising leaves the
gate open; for an outer/inner bridge siege then goes to BREACH at T+900 (core seal B2, refuge, B2_HOLD), the fallback
that exists for exactly this. So the fix never raises onto a unit because a wait was long; a raise in SIEGE/BREACH goes
ahead onto units on or next to the footprint only when a visible hostile stands within `force_near` tiles of it
(config/reflex.json `gate.force_near`, default 3, 0 = never): then the unit on the bridge is in the fight anyway, and
GATE_FORCED (A) names it. The Run 10 cases (enemy 100+ tiles away) never qualify.

## Fix (Claude, 2026-10-16)
- **Every pull waits for every unit that is not hostile** on the footprint or within `MARGIN` (1) tiles: raising and
  lowering, in every mode. Units by id only: `census.u.ids` (citizens, residents, soldiers and recruits; a soldier is
  named with his squad and its station order: `squad 3 stationed on the bridge at ...` / `on its way to its station ...`),
  `census.u.insane_ids` (children and babies are citizens; a carried baby counts where its carrier stands:
  `dfhack.units.getPosition`, not the stale `unit.pos`) and the fort's tame animals (`census.a`). An unknown census holds the pull silently
  (`stuck=census`, still a pull to do).
- **A pending pull of ours is cancelled** (`act.cancel_own_lever_job`, the UI cancel) as soon as such a unit is on or
  next to the footprint, in every mode and both ways, and queued again when it is clear. While one of our pulls is
  pending gate runs every frame (`M.PENDING`): a census pass every 25 ticks keeps the units within `SCAN_R` (5) tiles,
  the frames between re-read only their positions. What cannot be stopped is the bridge's own move (~100 ticks after
  the pull completed).
- **Forced raise only with a hostile at the gate** (`gate.force_near`, see the trade-off): `GATE_FORCED` (A) with
  `units`, `hostile` (tiles), `pos`, `job`; once per pull.
- **Names in the events.** GATE (C) `B1 up waits: soldier 26535 on the footprint (squad 3 ...)`, `units`, once per wanted
  state (a kern.log line when the holders change, at most every 300 ticks); GATE_FAIL `blocked` at the deadline:
  `B1 not up after 900 ticks (blocked: citizen 26099 on the footprint, never raised onto them)`, `units`, `pos`.
- **Stop-gap `gate.manual`** (config/reflex.json): bridge names (`"B1"`) or building ids (`17880`) that get no automatic
  pull at all (the inbox `lever` still pulls a manifest bridge in PEACE). For the game session meanwhile: add
  `"gate": {"manual": ["B1"]}` and reboot the kernel. This removes the inner gate from the defense: B1 stays down in a
  siege, GATE_FAIL `manual` at the deadline, BREACH at T+900 (B2 and the refuge). Prefer the occupancy fix.
- Contracts: GATE_FORCED (A) in `contract.lua`, `schema.py`, CONTRACTS §12, RULES §7; GATE_FAIL `units/pos`, GATE
  `units`; `gate.pulls().manual`; §9.18 `gate`; `python -m dfpilot.lint --config` checks `gate.force_near/manual`.

Tests (k_mock; every one fails on 6e34f8a except the lowering guard):
- `tests/lua/test_siege.lua`: a soldier on B1 in a SIEGE (army far away) holds it for good, GATE_FAIL names him, BREACH
  only once the army comes near (part 2), B1 never pulled (replaces the 300-ticks test); the T+450 raise of O1 waits for a citizen next to it; a
  pending SIEGE raise is cancelled when a miner steps on B1 and queued again; a tame animal holds B1; a hostile 2 tiles
  from B1 forces the raise onto the soldier with GATE_FORCED; `force_near 0` never forces; `gate.manual`.
- `tests/lua/test_gate_footprint.lua`: Run 10 on unmanaged bridges (invasion, 4 goblins far away: the recruit on X2, then
  a miner stepping on while the pull is pending: cancelled, GATE_FAIL names him, nobody on a moving bridge); the corridor:
  12 miners crossing B1 one every 30 ticks never see it move under them (the old code crushed miner 705); the lowering
  after the siege waits for a soldier on the raised B1; a baby in arms counts at its mother's position (getPosition).
- `tests/lua/test_drill.lua`: the raise KPI is seen sooner (T+585 instead of T+603) with the per-frame re-check.

### Part 2: order, waiting, slow pulls (Claude, 2026-10-16)
The y419 siege also showed `GATE_FAIL B1/O1 not up after 900 ticks (timeout)` and `BREACH O1 not up at T+900` while the
pulls were under way (live lever latency 11-19 s, i.e. 330-570 ticks at 30 t/s; siege's timer pull at T+450).
- **Call them in first** (reflex.lua `alert_due`, one rule): the lockdown's deferred civ alert sounds at once while a
  bridge it wants up waits for units on its footprint (`gate.pulls().foot`); the gate raises once the footprint is clear.
  siege sounds its alert at T0 anyway; soldiers are not confined by it, the GATE text names their squad station.
- **An occupied footprint is waiting, not a timeout.** The ticks a bridge waited for units do not count toward its `up`
  deadline; a bridge held on end for 900 ticks is GATE_FAIL `blocked` (with the names).
- **Slow pulls go to the backup lever.** A pull under way at the deadline (a worker took it, or the bridge moves) goes once
  to another linked lever (O1 has three, e.g. 17584/17585/17664) and gets max(300, the measured lever latency) ticks more,
  then GATE_FAIL `slow`. The GATE_FAIL text names the real seconds (`O1 not up after <ticks> ticks, <s> s (slow)`): the
  timeouts stay in game ticks because the pullers walk in game ticks, scaled by the measured latency.
- **No BREACH for a waiting bridge** (siege.lua `failed_bridge`): a bridge `gate.waiting` reports (`blocked`, `pulling`)
  is no failure while no hostile is within `NEAR_RAISE` (10) tiles of it.
- Not changed: siege's T+450 timer (an earlier timer shuts out more civilians; with the waiting rule the latency no longer
  turns into a BREACH). Soldiers are not moved off a bridge (a squad order is military's; the texts name the station).

Tests: `tests/lua/test_siege.lua` slow O1 pull at the deadline goes to the backup lever, no GATE_FAIL/BREACH; both levers
slow: GATE_FAIL `slow` at deadline + 300, then BREACH; the soldier on B1: BREACH only once the army is within 10 tiles.
`tests/lua/test_gate_footprint.lua`: a unit next to a lockdown bridge sounds the alert at once (the other slow pulls
do not hold it back), the bridge rises once he is inside. All fail on 1ded2eb.

Live check (next siege or a drill on Handlelock): with somebody on the B1 corridor, `events` shows
`GATE B1 up waits: ...` and no `LEVER pull B1 up` until the corridor is clear; kern.log has no
`raising B1 with a citizen on it`; no DEATH on (128,127..129,122).

Related: live L4 (the MARGIN rule), BUG-013 (lever pulls under the civ alert), BUG-022 (B1 built late), FR-64 (death causes)
