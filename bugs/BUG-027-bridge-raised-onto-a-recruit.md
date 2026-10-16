# BUG-027 the lockdown crushes citizens with bridge 17880 (seven deaths on B1 and O1)
Status: fixed (Claude, 2026-10-16; offline, live-untested)
Severity: critical (loses citizens: 7 confirmed deaths on the B1 and O1 footprints, recruits, a miner, a planter, a baby; enemy far away)
Found: 2026-10-16, Run 10 fort Handlelock, dfpilot main 6e34f8a; three raids (y417 autumn, y418 summer, y419 spring), reported by the orchestrator
Module: `lua/dfllm/gate.lua` (control: footprint check, the SIEGE/BREACH forced raise), called from `siege.lua` (O1/B1 at T+450) and `reflex.lua` (arrival lockdown)

## Cases
Bridge 17880 is the fortcore inner bridge **B1**, footprint (128,127..129,122) (BUG-022: "B1 (128,127,122) and its 3 levers stand"),
on the corridor x=128 that joins the core and the workshops: miners and soldiers cross it all the time.

1. **y417 autumn.** Raid (goblin snatcher + 3, `ARRIVAL invasion`, `SIEGE_START`). The lockdown and siege raised the bridges
   (`SEAL: 23 citizens shut out from bed by a raised bridge at 128,128,122`). Recruit **26535** died at **(128,127,122)**,
   on B1's footprint: `DEATH died: unknown (not found yet, missing in the unit list)`, no combat report; later a ghost
   without a body (`no_body`). Rest of the siege fine: `SIEGE_END 4 hostiles, 0 killed, 1 lost, sealed 11564 ticks`.
2. **y418 summer d41.** Same pattern: miner **26099** (a civilian) died at **(128,129,122)**, `unit.flags2.killed=true`,
   event #5163 `DEATH 'unknown'`, B1 `raised=true`, shortly after the lockdown (ARRIVAL invasion, SIEGE_START) raised the
   bridges. The enemy was far away (7,191,127); no combat report.

3. **y419 spring (siege still running at d30).** Five more deaths on bridge footprints. On B1 (128,127..129,122):
   planter **26098**, recruit **26463**, recruit **26818**, **baby 27608** (in arms: a carried baby is where its mother
   is). On **O1** (101,129,122): recruit **26666**. The kernel during this siege: `GATE_FAIL B1` and `GATE_FAIL O1`
   `not up after 900 ticks (timeout)`, `BREACH O1 not up at T+900`; the lockdown came only through the 60 s ack default.

Expected: a bridge is never pulled (raised or lowered) while a fort member stands on it or right next to it; with the
enemy hundreds of tiles away nobody can be crushed. Actual: B1 was raised onto them.

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
  at T+900, B1 never pulled (replaces the 300-ticks test); the T+450 raise of O1 waits for a citizen next to it; a
  pending SIEGE raise is cancelled when a miner steps on B1 and queued again; a tame animal holds B1; a hostile 2 tiles
  from B1 forces the raise onto the soldier with GATE_FORCED; `force_near 0` never forces; `gate.manual`.
- `tests/lua/test_gate_footprint.lua`: Run 10 on unmanaged bridges (invasion, 4 goblins far away: the recruit on X2, then
  a miner stepping on while the pull is pending: cancelled, GATE_FAIL names him, nobody on a moving bridge); the corridor:
  12 miners crossing B1 one every 30 ticks never see it move under them (the old code crushed miner 705); the lowering
  after the siege waits for a soldier on the raised B1; a baby in arms counts at its mother's position (getPosition).
- `tests/lua/test_drill.lua`: the raise KPI is seen sooner (T+585 instead of T+603) with the per-frame re-check.

Live check (next siege or a drill on Handlelock): with somebody on the B1 corridor, `events` shows
`GATE B1 up waits: ...` and no `LEVER pull B1 up` until the corridor is clear; kern.log has no
`raising B1 with a citizen on it`; no DEATH on (128,127..129,122).

Related: live L4 (the MARGIN rule), BUG-013 (lever pulls under the civ alert), BUG-022 (B1 built late), FR-64 (death causes)
