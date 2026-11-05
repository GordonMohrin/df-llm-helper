# BUG-462 Trolls destroyed the outer bridges although they stood up; no retreat, Pop 96 -> 1
Status: fixed (offline, live-untested); open: no fallback line is built during a siege, the plan has to supply it
Severity: critical (the fort fell)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y387 (`runs/run-16a/FR-BUGS.md` "Zweite Belagerung y387"; events #19670, #19727)
Module: `lua/dfllm/siege.lua` (`lost_step`), `lua/dfllm/seal.lua` (`M.lost`, `choose`, `leave_why`)

## Actual
Two trolls (Miner, Siege Engineer) toppled O1 (d29) and B2 (d39). Both events say `last up`: **a raised drawbridge is no barrier to a
building destroyer** (DF lets them attack the raised bridge in their path). 25 goblins came into Kern+, about 40 citizens were killed in
5 days; the civ alert stood on Kern+ (then none), the refuge was refused (BUG-464), no sortie was offered (BUG-452/463). The kernel did
see the destroyers: SIEGE_DEEP at the start (`2 building destroyers in sight (TROLL x2) ... civilians to Tiefe+`), but 66,000 ticks later
the refuge was refused for a single hungry citizen and nothing took the alert back to it.

## Root causes
1. The loss of a bridge changed the MODE only (SIEGE -> BREACH 'destroyed'). In a BREACH that had begun for another reason (gate_fail at
   T+900, as here) the loss had no trigger at all.
2. `seal.choose` kept Kern+ (fight_rule KEEP) as long as it was neither breached nor open, and refused the refuge for the dry mark (BUG-464).

## Fix
- `siege.lost_step` (SIEGE/BREACH, every 100 ticks until told): the first destroyed outer or inner bridge calls `seal.lost(name)` in the
  same pass that applies the alert (decide runs before apply) and re-issues the squads' orders.
- `seal.lost`: for the episode (cleared with the dry marks, persisted as `m.seal.lostb`) the refuge is the retreat of every ask; a dry mark
  of a FEW citizens (`seal.DRY_FEW` = 3, or under a fifth of those inside) refuses it neither in `choose` nor as a reason to leave it
  (`leave_why` 'dry').
- BUG-464's last resort covers the rest.
- No gate or bridge logic is touched. Raising stays the policy (a lowered bridge lets them walk in); the loss history and the wall + door
  replacement after `perimeter.stop_after` losses are unchanged. BRIDGE_DESTROYED's wake text says the retreat already happened.

## Not done
A fallback line (an inner door, hatch or wall behind the bridge, a trap hall) cannot be built during a siege; it is a plan item. `plan check`
already requires B1/B2 and the refuge hatch (building destroyers break a hatch: BUG-337/378 keep the citizens in Kern+ then).

## Tests
`tests/lua/test_bug462_siege_destroyers.lua` (the siege traffic test: citizens returning over B1, two trolls + four goblins down the gate
lane, O1 destroyed as the first troll passes it: SIEGE_DEEP before, `seal.lost` once within 400 ticks, BREACH `destroyed`, B1 up before the
army reaches it, nobody crushed or shut out, no GATE_FAIL), `tests/lua/test_bug462_464_retreat.lua` (seal.lost); the BUG-380 traffic tests
and the whole Lua suite unchanged.

## Live check
A siege with building destroyers whose first bridge falls: kern.log `siege: O1 destroyed in the BREACH: the civilians retreat to the refuge
now`, the alert burrow Tiefe+ within one siege step, REFUGE_SWITCH (B) if Kern+ was held.
