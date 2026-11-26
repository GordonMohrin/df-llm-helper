# BUG-909 SIEGE against building destroyers alone: a citizen beside the footprint holds the raise without bound (cave dragon 84 tiles out, 1739+ ticks)
Status: fixed (offline, live-untested); second round (15b): unchanged (SIEGE / BREACH only, no part of the ALERT crush)
Severity: medium
Found: Run 17 i3 Orangering y469 winter d26-29: ARRIVAL siege #34608, a cave dragon 84-92 tiles away (building destroyer, no timed force by design: BUG-881 round 3 decision A, BUG-462/030), `B1 up` pull #34628, GATE_FAIL #34641 `blocked: citizen 29043 next to it, never raised onto them`, held 1739+ ticks until the player's lever in the emergency exit. Diagnosis `leitung/neu10/DIAGNOSE-B1-2026-11-25.md` (claim D).
Module: `lua/dfllm/gate.lua` (`holders` FORCE branch: `bdo`, `near_now`, `rr.fz_bd`, `forced_event`)

## Live events (region1-site97, y469 winter, read from events.jsonl)
- #34608 t189434004 ARRIVAL siege (popup): `siege (popup) -> clock 30 t/s, alert: Kern+, recall: 10 outside Kern+ ... gates: 0 of 2 up` (goblin army, cave dragon 84-92 tiles out).
- #34628 t189434683 LEVER: `pull B1 up` (job 1026834, lever 18259).
- #34641 t189435755 GATE_FAIL: `B1 not up after 1739 ticks, 723 s (blocked: citizen 29043 next to it, never raised onto them)` at 85,63,142 (unit 29043, want up, why blocked).

## Cause
With only building destroyers in sight `barrier_foe` is false: no timed force. The plain approach rule (BUG-587) forces the raise at `approach_near` 30 tiles / `approach_hold` 300 ticks and BUG-775's release of the units STANDING beside the footprint comes only within `approach_now` 20 tiles: ~300 ticks before the destroyer is at the bridge, less than the pull and the move need; the deadline escape of `holders` restricts only crossers, not units within the margin.

## Fix
In the SIEGE/BREACH force branch (`d > force_near`): `bdo` = the hostile closes (`closing_tpt`), its eta `d x tpt` <= `CLOSE_BUDGET` (1500) ticks and `barrier_foe` is false. Then the BUG-775 release applies like within `approach_now`: units standing beside the footprint (`STILL_NOW` 60 ticks on one tile) no longer hold; a unit ON the footprint, one walking onto it (crossers) and one beside it that keeps moving still hold. GATE_FORCED names them with the reason ('a building destroyer D tiles from it closes in E ticks (within the 1500-tick budget)', `rr.fz_bd`). A destroyer that does not close (parked) releases nobody. No timed force, no deliberate crush.

## Second round (15b)
Not implicated in the live failures of round 15 (kernel 7f3706e5; no building destroyer in the ALERT of #38027..#38061) and kept as it is: the release applies only in SIEGE / BREACH (`FORCE_MODES`), where rounds 3 and 12 accept a bounded crush and a unit ON the footprint always holds. The 15b safety rule (BUG-907 reach rule) never applies there.

## Cost
A citizen standing beside the footprint when the raise goes ahead is not crushed (he stands beside it) but is locked out (the BUG-775 price, now from the destroyer's eta instead of 20 tiles); a unit that walks onto it as it moves is a crush risk exactly as in BUG-775. Nobody ON the footprint is touched.

## Tests
`test_bug905_909_b1.lua` (SIEGE, ONE cave dragon (race with buildingdestroyer raws) 84 tiles from B1 at 10 ticks a tile):
- a citizen standing 1 tile beside B1: pull +90, GATE_FORCED +135 `B1 raised with citizen 140 next to it: a building destroyer 74 tiles from it closes in 932 ticks ... held 81 ticks`, B1 up (flip) +171, +100 move = +271, the dragon is within 20 tiles at +640; 0 crushed;
- the citizen ON the footprint until +700: B1 never moves before, pull +711, up +792; 0 crushed;
- a parked dragon: the citizen beside it holds B1 down (1500 ticks).
On main the first test fails (up only with the approach rule at ~30 tiles). The BUG-881 round 3 tests (no GATE_FORCED before +800 for destroyers, streams) stay green.

## Live-Erwartung
In an ARRIVAL siege with only cave dragons / trolls in sight and a citizen standing beside B1: `GATE_FORCED B1 raised with citizen N next to it: a building destroyer D tiles from it closes in E ticks` within ~100-200 ticks of the first closing look, B1 up long before the dragon is within 20 tiles (i3 y469: not the 1739+ ticks of #34641). NOT promised: that B1 stops the dragon (it breaks raised bridges too) or that nobody is locked out.
