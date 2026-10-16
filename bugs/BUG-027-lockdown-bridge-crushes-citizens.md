# BUG-027 the lockdown raises bridge 17880 on top of citizens: two deaths on its footprint
Status: open (reported to the cloud session 2026-10-16; no fix yet)
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
